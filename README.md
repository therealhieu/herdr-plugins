# herdr-plugins

Plugins for [Herdr](https://herdr.dev). Each directory is a separately installable plugin.

| Plugin | What it does | Install | Needs |
|---|---|---|---|
| [stack](stack/) | Zellij-style stacked panes: the focused pane expands, siblings collapse to strips | `herdr plugin install therealhieu/herdr-plugins/stack` | cargo (Rust 1.89+) |
| [worktree-sidebar](worktree-sidebar/) | Sidebar tokens for Git worktrees: `$repo` parent name, `$dirty` count, `$branch` and `$sync` per agent | `herdr plugin install therealhieu/herdr-plugins/worktree-sidebar` | bash, git, jq |

Pin a revision with `--ref <tag-or-commit>`. A ref applies to the whole repository.

## Layout

```text
<plugin>/
├── herdr-plugin.toml   # manifest; runtime commands run from this directory
└── …                   # self-contained: no imports from sibling plugins
```

## Development

Link a working copy instead of installing (`plugin link` skips build commands):

```sh
herdr plugin link ./<plugin>
herdr plugin log list --plugin <plugin-id>
herdr plugin unlink <plugin-id>
```

Installing over a linked plugin is refused, so unlink first.

## License

MIT
