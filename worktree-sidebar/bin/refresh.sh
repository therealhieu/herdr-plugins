#!/usr/bin/env bash
# Report Git worktree tokens to the Herdr sidebar.
#
# Workspace tokens (Space rows):  $wt     "⎇" when the workspace is a linked worktree
#                                 $dirty  uncommitted file count, cleared when 0
# Pane tokens (Agent rows):       $wt     same marker
#                                 $repo   main repo name, only for linked worktrees
#
# Empty token values clear the key, so non-worktree spaces end up with no tokens.
set -euo pipefail

SOURCE="herdr-worktree-sidebar"
HERDR="${HERDR_BIN_PATH:-herdr}"
WT_MARK="${HERDR_WORKTREE_SIDEBAR_MARK:-⎇}"

command -v jq >/dev/null || { echo "herdr-worktree-sidebar: jq not found" >&2; exit 0; }

# Prints "<repo>\t<is_linked>\t<dirty>" for a directory, or nothing if it is not in Git.
git_info() {
  local dir=$1 top common repo linked dirty
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  common=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 0
  # The main checkout owns the common .git dir; a linked worktree lives elsewhere.
  repo=$(basename "$(dirname "$common")")
  linked=0
  [[ "$(dirname "$common")" != "$top" ]] && linked=1
  dirty=$(git -C "$top" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  printf '%s\t%s\t%s\n' "$repo" "$linked" "$dirty"
}

refresh_workspace() {
  local ws=$1 panes first_cwd info repo linked dirty wt
  panes=$("$HERDR" pane list --workspace "$ws" 2>/dev/null) || return 0

  first_cwd=$(jq -r '.result.panes[0].cwd // empty' <<<"$panes")
  [[ -n "$first_cwd" ]] || return 0
  info=$(git_info "$first_cwd")
  if [[ -z "$info" ]]; then
    "$HERDR" workspace report-metadata "$ws" --source "$SOURCE" \
      --clear-token wt --clear-token dirty >/dev/null
    return 0
  fi
  IFS=$'\t' read -r repo linked dirty <<<"$info"
  wt=""; [[ "$linked" == 1 ]] && wt="$WT_MARK"
  [[ "$dirty" == 0 ]] && dirty=""

  "$HERDR" workspace report-metadata "$ws" --source "$SOURCE" \
    --token "wt=$wt" --token "dirty=$dirty" >/dev/null

  # Each pane uses its own cwd: a pane may sit in a different checkout than the workspace.
  local pane_id cwd
  while IFS=$'\t' read -r pane_id cwd; do
    info=$(git_info "$cwd")
    repo=""; wt=""
    if [[ -n "$info" ]]; then
      IFS=$'\t' read -r repo linked _ <<<"$info"
      if [[ "$linked" == 1 ]]; then wt="$WT_MARK"; else repo=""; fi
    fi
    "$HERDR" pane report-metadata "$pane_id" --source "$SOURCE" \
      --token "wt=$wt" --token "repo=$repo" >/dev/null || true
  done < <(jq -r '.result.panes[] | [.pane_id, .cwd] | @tsv' <<<"$panes")
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
