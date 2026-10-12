#!/usr/bin/env bash
# Claude Code hook: keep Herdr in step with a Claude session that changes worktree.
#
# 1. Records the session cwd per terminal, so refresh.sh shows the worktree's branch.
#    Claude's EnterWorktree changes Claude's own cwd, not the process cwd Herdr reports.
# 2. With HERDR_WORKTREE_SIDEBAR_ADOPT=1, moves the Claude pane into a Herdr worktree
#    space on EnterWorktree, and back to the space it came from on ExitWorktree.
#
# Register for SessionStart, SessionEnd, and PostToolUse on EnterWorktree|ExitWorktree; see README.
# CwdChanged is not used: it also fires for a Bash `cd`, and not for the reset that follows.
set -euo pipefail

[[ -n "${HERDR_PANE_ID:-}" ]] || exit 0
command -v jq >/dev/null || exit 0

HERDR="${HERDR_BIN_PATH:-herdr}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-worktree-sidebar"

# Herdr renumbers a pane when it moves to another workspace but keeps its terminal,
# and still resolves the old pane id, so state is keyed by terminal id.
pane=$("$HERDR" pane get "$HERDR_PANE_ID" 2>/dev/null | jq -c '.result.pane // empty') || exit 0
[[ -n "$pane" ]] || exit 0
terminal=$(jq -r '.terminal_id' <<<"$pane")
cwd_file="$STATE/cwd/$terminal"
origin_file="$STATE/origin/$terminal"

input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input")
tool=$(jq -r '.tool_name // empty' <<<"$input")
# `cwd` is the session's working directory after the event.
cwd=$(jq -r '.cwd // empty' <<<"$input")

record_cwd() {
  [[ -n "$cwd" ]] || return 0
  mkdir -p "$STATE/cwd"
  printf '%s\n' "$cwd" >"$cwd_file"
}

focus_flag() {
  [[ $(jq -r '.focused' <<<"$pane") == true ]] && echo --focus || echo --no-focus
}

# Opens (or reuses) the worktree space for $cwd and moves this pane next to its first pane.
adopt() {
  local ws tab opened target_ws target_tab target_pane
  ws=$(jq -r '.workspace_id' <<<"$pane")
  tab=$(jq -r '.tab_id' <<<"$pane")
  # Already in this worktree's space.
  [[ $("$HERDR" workspace get "$ws" | jq -r '.result.workspace.worktree.checkout_path // empty') == "$cwd" ]] && return 0

  opened=$("$HERDR" worktree open --workspace "$ws" --path "$cwd" --no-focus) || return 0
  target_ws=$(jq -r '.result.workspace.workspace_id' <<<"$opened")
  target_tab=$(jq -r '.result.workspace.active_tab_id' <<<"$opened")
  target_pane=$("$HERDR" pane list --workspace "$target_ws" |
    jq -r --arg t "$target_tab" '[.result.panes[] | select(.tab_id == $t)][0].pane_id // empty')
  [[ -n "$target_pane" ]] || return 0

  mkdir -p "$STATE/origin"
  printf '%s\t%s\n' "$ws" "$tab" >"$origin_file"
  "$HERDR" pane move "$HERDR_PANE_ID" --tab "$target_tab" --split right \
    --target-pane "$target_pane" "$(focus_flag)" >/dev/null
}

# A pane Herdr may close: no agent, and the shell itself is in the foreground.
idle_shell() {
  local info
  info=$("$HERDR" pane process-info --pane "$1" 2>/dev/null) || return 1
  jq -e '.result.process_info | .foreground_process_group_id == .shell_pid' <<<"$info" >/dev/null
}

# Moves this pane back to the space it came from; closes the worktree space if only idle shells remain.
release() {
  local ws origin_ws origin_tab others pane_id
  [[ -f "$origin_file" ]] || return 0
  IFS=$'\t' read -r origin_ws origin_tab <"$origin_file"
  rm -f "$origin_file"
  ws=$(jq -r '.workspace_id' <<<"$pane")
  [[ "$ws" != "$origin_ws" ]] || return 0
  "$HERDR" workspace get "$origin_ws" >/dev/null 2>&1 || return 0

  if "$HERDR" tab get "$origin_tab" >/dev/null 2>&1; then
    "$HERDR" pane move "$HERDR_PANE_ID" --tab "$origin_tab" --split right "$(focus_flag)" >/dev/null || return 0
  else
    "$HERDR" pane move "$HERDR_PANE_ID" --new-tab --workspace "$origin_ws" "$(focus_flag)" >/dev/null || return 0
  fi

  others=$("$HERDR" pane list --workspace "$ws" 2>/dev/null) || return 0
  jq -e '[.result.panes[] | select(.agent != null)] | length == 0' <<<"$others" >/dev/null || return 0
  for pane_id in $(jq -r '.result.panes[].pane_id' <<<"$others"); do
    idle_shell "$pane_id" || return 0
  done
  "$HERDR" workspace close "$ws" >/dev/null || true
}

case "$event" in
  SessionStart)
    record_cwd ;;
  SessionEnd)
    rm -f "$cwd_file" "$origin_file"; exit 0 ;;
  PostToolUse)
    record_cwd
    if [[ "${HERDR_WORKTREE_SIDEBAR_ADOPT:-}" == 1 ]]; then
      case "$tool" in
        EnterWorktree) adopt || true ;;
        ExitWorktree)  release || true ;;
      esac
    fi ;;
  *) exit 0 ;;
esac

"$HERDR" plugin action invoke refresh --plugin herdr-worktree-sidebar >/dev/null 2>&1 || true
