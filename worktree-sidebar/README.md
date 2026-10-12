# herdr-worktree-sidebar

Git worktree context for the [Herdr](https://herdr.dev) sidebar, as a plugin on stock Herdr.
It reports custom tokens that your `ui.sidebar` layouts can show.

```text
spaces                          agents
○ llamport                      ● llamport · rm-2611-auth · done
  ○ ⎇ rm-261009-fix · 3 ↑1        Refactor auth middleware
    feat/rm261009…
  ● ⎇ rm-2611-auth
    feat/rm2611-…
```

## Tokens

| Token | Panel | Value |
|---|---|---|
| `$wt` | Spaces, Agents | `⎇` when the checkout is a linked Git worktree; empty otherwise |
| `$dirty` | Spaces | Uncommitted file count (`git status --porcelain`); empty when clean |
| `$repo` | Agents | Main repo name, only for panes inside a linked worktree |

Worktrees are detected from Git itself (`--git-common-dir` vs `--show-toplevel`),
so checkouts created outside Herdr work too.

## When tokens refresh

| Trigger | Scope |
|---|---|
| Server startup | All workspaces |
| `workspace.created`, `worktree.created`, `worktree.opened`, `pane.created` | That workspace |
| `pane.agent_status_changed` | That workspace (an agent finishing is when files usually change) |
| Action `herdr-worktree-sidebar.refresh` | All workspaces |

`$dirty` does not follow edits you make yourself in a shell until the next trigger.
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
  ["state_icon", { token = "$wt", fg = "#6c7086" }, "workspace",
   { token = "$dirty", fg = "#f9e2af" }, "git_status"],
  [{ token = "branch", dim = true, rules = [
      { equals = "master", hide = true }, { equals = "main", hide = true }]}],
]

[ui.sidebar.agents]
rows = [
  ["state_icon", { token = "$repo", dim = true }, "workspace", "state_text"],
  ["agent"],
]

[ui.sidebar.agents.rows_by_agent]
claude = [
  ["state_icon", { token = "$repo", dim = true }, "workspace", "state_text"],
  [{ token = "terminal_title_stripped", dim = true }],
]

[[keys.command]]
key = "prefix+shift+r"
type = "plugin_action"
command = "herdr-worktree-sidebar.refresh"
description = "worktree sidebar: refresh"
```

Change the marker with `HERDR_WORKTREE_SIDEBAR_MARK` in the Herdr server environment.

## Troubleshooting

```bash
herdr plugin log list --plugin herdr-worktree-sidebar
herdr api snapshot | jq '.result.snapshot.workspaces[] | {label, tokens}'
```

## License

MIT
