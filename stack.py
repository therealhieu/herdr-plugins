#!/usr/bin/env python3
"""herdr-stack: Zellij-style stacked panes on stock Herdr.

On pane focus, every split between the tab's top split and the focused pane
is resized so the focused pane takes the space and its siblings shrink to
thin strips. The tab's top split (e.g. the left/right halves) is left alone,
so each side of it stacks independently.

Optional overrides: $HERDR_PLUGIN_CONFIG_DIR/config.json with any DEFAULTS key.

Uses only the public socket API: layout.export, pane.layout,
layout.set_split_ratio.
"""
import fcntl
import json
import os
import socket
import sys

DEFAULTS = {
    "collapsed_rows": 3,   # height of a collapsed pane in a stacked (down) split
    "collapsed_cols": 20,  # width of a collapsed pane in a side-by-side (right) split
    "skip_root": True,     # never resize the tab's top split
}
MIN_RATIO, MAX_RATIO = 0.1, 0.9  # Herdr clamps split ratios to this range


def load_config():
    cfg = dict(DEFAULTS)
    path = os.path.join(os.environ.get("HERDR_PLUGIN_CONFIG_DIR", ""), "config.json")
    try:
        with open(path) as f:
            cfg.update(json.load(f))
    except (OSError, ValueError):
        pass
    return cfg


class Api:
    """Herdr socket client. The server answers one request per connection."""

    def __init__(self, path):
        self.path = path
        self.seq = 0

    def call(self, method, params):
        self.seq += 1
        req = {"id": f"stack-{self.seq}", "method": method, "params": params}
        with socket.socket(socket.AF_UNIX) as sock:
            sock.connect(self.path)
            sock.sendall((json.dumps(req) + "\n").encode())
            resp = json.loads(sock.makefile("r").readline())
        if "error" in resp:
            raise RuntimeError(f"{method}: {resp['error']}")
        return resp["result"]


def find_path(node, pane_id, path=()):
    """Return the list of booleans (False=first, True=second) leading to pane_id."""
    if node["type"] == "pane":
        return list(path) if node.get("pane_id") == pane_id else None
    return (find_path(node["first"], pane_id, path + (False,))
            or find_path(node["second"], pane_id, path + (True,)))


def span(node, axis):
    """How many collapsed strips a subtree needs along axis ('down' or 'right')."""
    if node["type"] == "pane":
        return 1
    a, b = span(node["first"], axis), span(node["second"], axis)
    return a + b if node["direction"] == axis else max(a, b)


def plan(node, size, path, target, cfg, depth, out, collapsed=False):
    """Collect (path, ratio) updates. size = {'down': rows, 'right': cols} of node.

    collapsed marks a subtree squeezed into strips beside the focused pane.
    """
    if node["type"] == "pane":
        return
    axis = node["direction"]
    total = size[axis]
    first, second = node["first"], node["second"]
    on_path = target is not None and target[:len(path)] == path
    unit = cfg["collapsed_rows"] if axis == "down" else cfg["collapsed_cols"]

    if on_path and depth == 0 and cfg["skip_root"]:
        ratio = node["ratio"]
    elif on_path:
        # Focused pane's side gets everything except the strips for the other side.
        focused_second = target[len(path)]
        other = second if not focused_second else first
        other_size = unit * span(other, axis)
        r = 1 - other_size / total if total else 0.5
        ratio = r if not focused_second else 1 - r
    elif collapsed:
        # Inside a collapsed region: share space by strip count so bars are even.
        a, b = span(first, axis), span(second, axis)
        ratio = a / (a + b)
    else:
        ratio = node["ratio"]  # unrelated part of the tab: leave it alone

    ratio = min(MAX_RATIO, max(MIN_RATIO, ratio))
    if abs(ratio - node["ratio"]) > 1e-3:
        out.append((list(path), ratio))

    first_size, second_size = dict(size), dict(size)
    first_size[axis] = total * ratio
    second_size[axis] = total - first_size[axis]
    accordion = on_path and not (depth == 0 and cfg["skip_root"])
    for child, child_size, step in ((first, first_size, False), (second, second_size, True)):
        child_on_path = on_path and target[len(path)] == step
        child_collapsed = collapsed or (accordion and not child_on_path)
        plan(child, child_size, path + [step], target,
             cfg, depth + 1, out, child_collapsed)


def focused_pane_id():
    raw = os.environ.get("HERDR_PLUGIN_EVENT_JSON", "")
    try:
        event = json.loads(raw)
    except ValueError:
        event = {}
    for obj in (event, event.get("data") or {}, event.get("event") or {}):
        if isinstance(obj, dict) and obj.get("pane_id"):
            return obj["pane_id"]
    if len(sys.argv) > 1 and sys.argv[1] != "toggle":
        return sys.argv[1]
    return os.environ.get("HERDR_PANE_ID")


def state_path(name):
    return os.path.join(os.environ.get("HERDR_PLUGIN_STATE_DIR") or "/tmp", name)


def load_disabled_tabs():
    try:
        with open(state_path("disabled-tabs.json")) as f:
            return set(json.load(f))
    except (OSError, ValueError):
        return set()


def save_disabled_tabs(tabs):
    with open(state_path("disabled-tabs.json"), "w") as f:
        json.dump(sorted(tabs), f)


def stack(api, pane_id, cfg):
    layout = api.call("layout.export", {"pane_id": pane_id})["layout"]
    if layout.get("zoomed") or layout["focused_pane_id"] != pane_id:
        return  # zoomed, or focus already moved on; a newer event will handle it
    if layout["tab_id"] in load_disabled_tabs():
        return
    root = layout["root"]
    target = find_path(root, pane_id)
    if target is None:
        return

    area = api.call("pane.layout", {"pane_id": pane_id})["layout"]["area"]
    updates = []
    plan(root, {"down": area["height"], "right": area["width"]}, [], target, cfg, 0, updates)
    for path, ratio in updates:
        api.call("layout.set_split_ratio",
                 {"tab_id": layout["tab_id"], "path": path, "ratio": round(ratio, 4)})


def toggle(api, pane_id, cfg):
    """Turn stacking off or on for the focused pane's tab."""
    tab_id = api.call("pane.get", {"pane_id": pane_id})["pane"]["tab_id"]
    disabled = load_disabled_tabs()
    if tab_id in disabled:
        disabled.discard(tab_id)
        save_disabled_tabs(disabled)
        stack(api, pane_id, cfg)
        title = "Stack: on for this tab"
    else:
        disabled.add(tab_id)
        save_disabled_tabs(disabled)
        title = "Stack: off for this tab"
    api.call("notification.show", {"title": title})


def main():
    pane_id = focused_pane_id()
    sock_path = os.environ.get("HERDR_SOCKET_PATH")
    if not pane_id or not sock_path:
        return
    cfg = load_config()

    # Serialize runs: rapid focus changes must not interleave their writes.
    lock = open(state_path("stack.lock"), "w")
    fcntl.flock(lock, fcntl.LOCK_EX)

    api = Api(sock_path)
    if sys.argv[1:2] == ["toggle"]:
        toggle(api, pane_id, cfg)
    else:
        stack(api, pane_id, cfg)


if __name__ == "__main__":
    main()
