#!/usr/bin/env bash
# Report Git worktree tokens to the Herdr sidebar.
#
# Workspace tokens (Space rows):  $dirty  uncommitted file count, cleared when 0
# Pane tokens (Agent rows):       $repo   main repo name, only for linked worktrees
#                                 $branch branch name, or short SHA when detached
#                                 $dirty  uncommitted file count, cleared when 0
#                                 $sync   "↑ahead ↓behind" vs upstream, cleared when even
#
# Empty token values clear the key, so non-worktree spaces end up with no tokens.
set -euo pipefail

SOURCE="herdr-worktree-sidebar"
HERDR="${HERDR_BIN_PATH:-herdr}"

command -v jq >/dev/null || { echo "herdr-worktree-sidebar: jq not found" >&2; exit 0; }

# Prints "<repo>\t<is_linked>\t<dirty>\t<branch>\t<ahead>\t<behind>" for a directory,
# or nothing if it is not in Git. Every field is non-empty: `read` collapses empty tab fields.
git_info() {
  local dir=$1 top common repo linked status
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  # The main checkout owns the common .git dir; a linked worktree lives elsewhere.
  repo=$(basename "$(dirname "$common")")
  linked=0
  [[ "$(dirname "$common")" != "$top" ]] && linked=1
  # One call gives branch, upstream divergence, and changed entries.
  status=$(git -C "$top" status --porcelain=v2 --branch 2>/dev/null) || return 0
  awk -v repo="$repo" -v linked="$linked" '
    /^# branch\.oid /  { oid = substr($3, 1, 7) }
    /^# branch\.head / { head = $3 }
    /^# branch\.ab /   { ahead = substr($3, 2); behind = substr($4, 2) }
    !/^#/              { dirty++ }
    END {
      if (head == "(detached)" || head == "") head = oid
      printf "%s\t%s\t%d\t%s\t%d\t%d\n", repo, linked, dirty, head, ahead, behind
    }' <<<"$status"
}

# Formats ahead/behind counts as "↑1 ↓2", dropping zero sides.
sync_text() {
  local ahead=$1 behind=$2 out=""
  (( ahead > 0 )) && out="↑$ahead"
  (( behind > 0 )) && out="${out:+$out }↓$behind"
  printf '%s' "$out"
}

# Prints the cwd an agent reported for a terminal (see claude-cwd-hook.sh), else the fallback.
# Herdr's pane cwd is the process cwd, which Claude's EnterWorktree does not change.
# Keyed by terminal id because a pane moved to another workspace gets a new pane id.
pane_cwd() {
  local terminal=$1 fallback=$2 file cwd
  file="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-worktree-sidebar/cwd/$terminal"
  if [[ -f "$file" ]]; then
    cwd=$(<"$file")
    # A removed worktree falls back to the process cwd.
    if [[ -d "$cwd" ]]; then printf '%s' "$cwd"; return; fi
    rm -f "$file"
  fi
  printf '%s' "$fallback"
}

refresh_workspace() {
  local ws=$1 panes first_cwd info repo linked dirty
  panes=$("$HERDR" pane list --workspace "$ws" 2>/dev/null) || return 0

  first_cwd=$(jq -r '.result.panes[0].cwd // empty' <<<"$panes")
  [[ -n "$first_cwd" ]] || return 0
  info=$(git_info "$first_cwd")
  if [[ -z "$info" ]]; then
    "$HERDR" workspace report-metadata "$ws" --source "$SOURCE" \
      --clear-token dirty >/dev/null
    return 0
  fi
  IFS=$'\t' read -r repo linked dirty _ <<<"$info"
  [[ "$dirty" == 0 ]] && dirty=""

  "$HERDR" workspace report-metadata "$ws" --source "$SOURCE" \
    --token "dirty=$dirty" >/dev/null

  # Each pane uses its own cwd: a pane may sit in a different checkout than the workspace.
  local pane_id terminal cwd branch ahead behind sync
  while IFS=$'\t' read -r pane_id terminal cwd; do
    info=$(git_info "$(pane_cwd "$terminal" "$cwd")")
    repo=""; dirty=""; branch=""; sync=""
    if [[ -n "$info" ]]; then
      IFS=$'\t' read -r repo linked dirty branch ahead behind <<<"$info"
      [[ "$linked" == 1 ]] || repo=""
      [[ "$dirty" == 0 ]] && dirty=""
      sync=$(sync_text "$ahead" "$behind")
    fi
    "$HERDR" pane report-metadata "$pane_id" --source "$SOURCE" \
      --token "repo=$repo" --token "branch=$branch" \
      --token "dirty=$dirty" --token "sync=$sync" >/dev/null || true
  done < <(jq -r '.result.panes[] | [.pane_id, .terminal_id, .cwd] | @tsv' <<<"$panes")
}

all_workspaces() {
  "$HERDR" workspace list | jq -r '.result.workspaces[].workspace_id'
}

# Event payload shapes differ per event; take the first workspace_id anywhere in it.
event_workspace() {
  [[ -n "${HERDR_WORKSPACE_ID:-}" ]] && { echo "$HERDR_WORKSPACE_ID"; return; }
  [[ -n "${HERDR_PLUGIN_EVENT_JSON:-}" ]] || return 0
  jq -r '[.. | objects | .workspace_id? // empty] | first // empty' <<<"$HERDR_PLUGIN_EVENT_JSON"
}

main() {
  local ws
  if [[ "${1:-}" == "--all" || "${HERDR_PLUGIN_EVENT:-}" == "startup" ]]; then
    for ws in $(all_workspaces); do refresh_workspace "$ws"; done
    return
  fi
  ws=$(event_workspace)
  if [[ -n "$ws" ]]; then
    refresh_workspace "$ws"
  else
    for ws in $(all_workspaces); do refresh_workspace "$ws"; done
  fi
}

main "$@"
