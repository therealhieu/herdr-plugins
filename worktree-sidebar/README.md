# herdr-worktree-sidebar

Git worktree context for the [Herdr](https://herdr.dev) sidebar, as a plugin on stock Herdr.
It reports custom tokens that your `ui.sidebar` layouts can show.

```text
spaces                          agents
○ llamport                      ● llamport · rm-2611-auth · done
  ○ rm-261009-fix · 3 ↑1        Refactor auth middleware
    feat/rm261009…
  ● rm-2611-auth
    feat/rm2611-…
```

## Tokens

| Token | Panel | Value |
|---|---|---|
| `$dirty` | Spaces, Agents | Uncommitted file count (`git status --porcelain`); empty when clean |
| `$repo` | Agents | Main repo name, only for panes inside a linked worktree |
| `$branch` | Agents | Branch of the pane's checkout; short SHA when detached |
| `$sync` | Agents | `↑ahead ↓behind` vs upstream; empty when even or no upstream |

Agent rows have no built-in `branch`/`git_status` tokens, so these pane tokens fill that gap.

Worktrees are detected from Git itself (`--git-common-dir` vs `--show-toplevel`),
so checkouts created outside Herdr work too.

## When tokens refresh

| Trigger | Scope |
|---|---|
| Server startup | All workspaces |
| `workspace.created`, `worktree.created`, `worktree.opened`, `pane.created` | That workspace |
| `pane.agent_status_changed` | That workspace (an agent finishing is when files usually change) |
| `pane.focused` (also fires when switching spaces) | That workspace (catches a checkout or commit made in a shell) |
| Action `herdr-worktree-sidebar.refresh` | All workspaces |

Herdr plugins have no timer, so tokens do not follow a shell `git checkout` until the next trigger, such as focusing another pane.
Bind the refresh action to a key if you want a manual refresh.

## Install

Requires Herdr 0.9.1+, `bash`, `git`, and `jq`. Linux and macOS.

```bash
herdr plugin install therealhieu/herdr-plugins/worktree-sidebar
```

## Configure

Add the tokens to your `~/.config/herdr/config.toml`, then run `herdr server reload-config`:

```toml
[ui.sidebar.spaces]
row_gap = 1
rows = [
  ["state_icon", "workspace",
   { token = "$dirty", fg = "#f9e2af" }, "git_status"],
  [{ token = "branch", dim = true, rules = [
      { equals = "master", hide = true }, { equals = "main", hide = true }]}],
]

[ui.sidebar.agents]
rows = [
  ["state_icon", { token = "$repo", dim = true }, "workspace", "state_text"],
  [{ token = "$branch", fg = "#89b4fa", dim = true }, { token = "$dirty", fg = "#f9e2af" },
   { token = "$sync", fg = "#a6e3a1" }],
  ["agent"],
]

[ui.sidebar.agents.rows_by_agent]
claude = [
  ["state_icon", { token = "$repo", dim = true }, "workspace"],
  [{ token = "$branch", fg = "#89b4fa", dim = true }, { token = "$dirty", fg = "#f9e2af" },
   { token = "$sync", fg = "#a6e3a1" }],
  [{ token = "terminal_title_stripped", dim = true }],
]

[[keys.command]]
key = "prefix+shift+r"
type = "plugin_action"
command = "herdr-worktree-sidebar.refresh"
description = "worktree sidebar: refresh"
```

## Claude Code worktrees

Herdr reports a pane's process cwd. Claude Code's `EnterWorktree` changes Claude's own cwd but not the process cwd,
so a session that moves into a worktree keeps showing the original checkout's branch.

`bin/claude-cwd-hook.sh` fixes this: it records Claude's cwd per terminal under
`${XDG_STATE_HOME:-~/.local/state}/herdr-worktree-sidebar/cwd/` and triggers a refresh.
`refresh.sh` prefers that recorded cwd while the directory exists.
Register it in `~/.claude/settings.json`, pointing at a copy of the script:

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command", "command": "bash /path/to/claude-cwd-hook.sh" }] }],
    "SessionEnd":   [{ "hooks": [{ "type": "command", "command": "bash /path/to/claude-cwd-hook.sh" }] }],
    "PostToolUse":  [{ "matcher": "EnterWorktree|ExitWorktree",
                       "hooks": [{ "type": "command", "command": "bash /path/to/claude-cwd-hook.sh" }] }]
  }
}
```

`CwdChanged` is deliberately not used: it also fires for a Bash `cd`, and not for the reset that follows.
The hook is a no-op outside Herdr (no `HERDR_PANE_ID`).

### Move the session into a worktree space

Set `HERDR_WORKTREE_SIDEBAR_ADOPT=1` (for example in the `env` block of `~/.claude/settings.json`)
to get the worktree space without creating it yourself:

```text
EnterWorktree → herdr worktree open (or reuse the open space)
              → move the Claude pane right of that space's shell, keeping focus if it had it
ExitWorktree  → move the pane back to the tab it came from (a new tab if that tab is gone)
              → close the worktree space if only idle shells remain
```

The Claude process keeps running; Herdr gives the moved pane a new pane id but still resolves the old one,
so `HERDR_PANE_ID` keeps working. A worktree space with a busy shell (a dev server, say) is left open.

## Troubleshooting

```bash
herdr plugin log list --plugin herdr-worktree-sidebar
herdr api snapshot | jq '.result.snapshot.workspaces[] | {label, tokens}'
```

## License

MIT
