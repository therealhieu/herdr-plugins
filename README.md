# herdr-stack

Zellij-style stacked panes for [Herdr](https://herdr.dev), as a plugin on stock Herdr.
The focused pane expands; its siblings collapse to thin strips but stay visible.

```text
┌──────────────┬──────────────┐
│ p1  ▸ strip  │ p4  ▸ strip  │
├──────────────┼──────────────┤
│ p2  focused  │ p5  last     │
│ (fills rest) │ focused      │
├──────────────┤              │
│ p3  ▸ strip  │              │
└──────────────┴──────────────┘
```

- Each side of the tab's top split stacks independently; the top split itself is never resized.
- Works for stacked (`down`) and side-by-side (`right`) splits, nested to any depth.
- Per-tab on/off toggle.
- Uses only Herdr's public socket API (`layout.export`, `pane.layout`, `layout.set_split_ratio`), so it needs no rebuild when Herdr updates.

## Requirements

- Herdr ≥ 0.9.1 (macOS or Linux)
- `python3` on `PATH` (standard library only)

## Install

```sh
git clone <this-repo> ~/git/herdr-stack
herdr plugin link ~/git/herdr-stack
```

Optional toggle key in `~/.config/herdr/config.toml`:

```toml
[[keys.command]]
key = "prefix+shift+s"
type = "plugin_action"
command = "local.stack.toggle"
description = "stack: toggle for this tab"
```

Then `herdr server reload-config`.

## Usage

Split panes as usual and move focus (`prefix+h/j/k/l` or mouse). The focused pane expands.

| Goal | How |
|---|---|
| Toggle stacking for the current tab | `prefix+shift+s` (or `herdr plugin action invoke local.stack.toggle`) |
| Disable everywhere | `herdr plugin disable local.stack` |
| Re-enable | `herdr plugin enable local.stack` |
| Uninstall | `herdr plugin unlink local.stack` |

Disabling leaves pane sizes as they are.

## Configuration

Optional `$(herdr plugin config-dir local.stack)/config.json`:

```json
{
  "collapsed_rows": 3,
  "collapsed_cols": 20,
  "skip_root": true
}
```

| Key | Default | Meaning |
|---|---|---|
| `collapsed_rows` | `3` | Height of a collapsed pane in a stacked split |
| `collapsed_cols` | `20` | Width of a collapsed pane in a side-by-side split |
| `skip_root` | `true` | Never resize the tab's top split. Set `false` to stack across the whole tab |

## How it works

```text
pane.focused event
  → layout.export          (BSP tree of the focused pane's tab)
  → find path to the focused pane
  → for each split on that path (below the root):
        focused side = total − collapsed size of the other side
  → inside collapsed regions: share space evenly by strip count
  → layout.set_split_ratio for each changed split
```

Runs are serialized with a file lock so rapid focus changes don't interleave.
Disabled tabs are stored in `$HERDR_PLUGIN_STATE_DIR/disabled-tabs.json`.

## Limitations

- Herdr clamps split ratios to 0.1–0.9, so a strip is at least 10% of its split. Strips are typically 3–4 rows rather than Zellij's single title line.
- Resizing happens just after the focus change, so a brief re-layout is visible.
- Zoomed tabs are skipped.
