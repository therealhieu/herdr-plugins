#!/usr/bin/env bash
# Claude Code hook: record the session's working directory for its Herdr pane.
#
# Claude's EnterWorktree changes Claude's own cwd but not the process cwd that Herdr
# reports, so refresh.sh would keep showing the original checkout's branch.
# Register for SessionStart, SessionEnd, and PostToolUse on EnterWorktree|ExitWorktree; see README.
# CwdChanged is not used: it also fires for a Bash `cd`, and not for the reset that follows.
set -euo pipefail

[[ -n "${HERDR_PANE_ID:-}" ]] || exit 0
command -v jq >/dev/null || exit 0

dir="${XDG_STATE_HOME:-$HOME/.local/state}/herdr-worktree-sidebar/cwd"
file="$dir/${HERDR_PANE_ID//[^A-Za-z0-9_-]/_}"
input=$(cat)

case $(jq -r '.hook_event_name // empty' <<<"$input") in
  SessionStart) ;;
  PostToolUse)
    case $(jq -r '.tool_name // empty' <<<"$input") in
      EnterWorktree|ExitWorktree) ;;
      *) exit 0 ;;
    esac ;;
  SessionEnd) rm -f "$file"; exit 0 ;;
  *) exit 0 ;;
esac

# `cwd` is the session's working directory after the event.
cwd=$(jq -r '.cwd // empty' <<<"$input")
[[ -n "$cwd" ]] || exit 0
mkdir -p "$dir"
printf '%s\n' "$cwd" >"$file"
"${HERDR_BIN_PATH:-herdr}" plugin action invoke refresh --plugin herdr-worktree-sidebar >/dev/null 2>&1 || true
