//! herdr-stack: Zellij-style stacked panes on stock Herdr.
//!
//! On pane focus, every split between the tab's top split and the focused pane
//! is resized so the focused pane takes the space and its siblings shrink to
//! thin strips. The tab's top split (e.g. the left/right halves) is left alone,
//! so each side of it stacks independently.
//!
//! Usage (from the plugin manifest):
//!   herdr-stack            handle a `pane.focused` event
//!   herdr-stack toggle     turn stacking off/on for the focused pane's tab
//!   herdr-stack <pane_id>  stack around a pane (manual testing)
//!
//! Optional overrides: $HERDR_PLUGIN_CONFIG_DIR/config.json.
//! Uses only the public socket API: layout.export, pane.layout, pane.get,
//! layout.set_split_ratio, notification.show.

mod api;
mod layout;

use api::Api;
use layout::{plan, Config, Node};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::env;
use std::fs::{self, File};
use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    match run() {
        Ok(()) => ExitCode::SUCCESS,
        Err(err) => {
            eprintln!("herdr-stack: {err}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> Result<(), String> {
    let arg = env::args().nth(1);
    let toggle_mode = arg.as_deref() == Some("toggle");
    let manual_pane = arg.filter(|_| !toggle_mode);

    let Some(pane_id) = focused_pane_id(manual_pane) else { return Ok(()) };
    let Ok(socket) = env::var("HERDR_SOCKET_PATH") else { return Ok(()) };
    let cfg = load_config();

    // Serialize runs: rapid focus changes must not interleave their writes.
    let lock = File::create(state_path("stack.lock")).map_err(|e| format!("lock file: {e}"))?;
    lock.lock().map_err(|e| format!("lock: {e}"))?;

    let mut api = Api::new(socket);
    if toggle_mode {
        toggle(&mut api, &pane_id, &cfg)
    } else {
        stack(&mut api, &pane_id, &cfg)
    }
}

fn stack(api: &mut Api, pane_id: &str, cfg: &Config) -> Result<(), String> {
    let layout = api.call("layout.export", json!({ "pane_id": pane_id }))?["layout"].take();
    if layout["zoomed"].as_bool() == Some(true) || layout["focused_pane_id"] != pane_id {
        return Ok(()); // zoomed, or focus already moved on; a newer event will handle it
    }
    let tab_id = layout["tab_id"].as_str().unwrap_or_default().to_string();
    if load_disabled_tabs().contains(&tab_id) {
        return Ok(());
    }
    let root = Node::from_json(&layout["root"])?;
    let Some(target) = root.find_path(pane_id) else { return Ok(()) };

    let area = api.call("pane.layout", json!({ "pane_id": pane_id }))?["layout"]["area"].take();
    let rows = area["height"].as_f64().unwrap_or(0.0);
    let cols = area["width"].as_f64().unwrap_or(0.0);

    for (path, ratio) in plan(&root, &target, rows, cols, cfg) {
        let ratio = (ratio * 10_000.0).round() / 10_000.0;
        api.call("layout.set_split_ratio", json!({ "tab_id": tab_id, "path": path, "ratio": ratio }))?;
    }
    Ok(())
}

fn toggle(api: &mut Api, pane_id: &str, cfg: &Config) -> Result<(), String> {
    let pane = api.call("pane.get", json!({ "pane_id": pane_id }))?;
    let tab_id = pane["pane"]["tab_id"].as_str().ok_or("pane.get: no tab_id")?.to_string();

    let mut disabled = load_disabled_tabs();
    let title = if disabled.remove(&tab_id) {
        save_disabled_tabs(&disabled)?;
        stack(api, pane_id, cfg)?;
        "Stack: on for this tab"
    } else {
        disabled.insert(tab_id);
        save_disabled_tabs(&disabled)?;
        "Stack: off for this tab"
    };
    api.call("notification.show", json!({ "title": title }))?;
    Ok(())
}

/// The focused pane: from the event payload, a manual argument, or the
/// invocation context.
fn focused_pane_id(manual: Option<String>) -> Option<String> {
    if let Ok(raw) = env::var("HERDR_PLUGIN_EVENT_JSON") {
        if let Ok(event) = serde_json::from_str::<Value>(&raw) {
            for obj in [&event, &event["data"], &event["event"]] {
                if let Some(id) = obj["pane_id"].as_str() {
                    return Some(id.to_string());
                }
            }
        }
    }
    manual.or_else(|| env::var("HERDR_PANE_ID").ok())
}

fn load_config() -> Config {
    let mut cfg = Config::default();
    let path = PathBuf::from(env::var("HERDR_PLUGIN_CONFIG_DIR").unwrap_or_default()).join("config.json");
    let Ok(text) = fs::read_to_string(path) else { return cfg };
    let Ok(user) = serde_json::from_str::<Value>(&text) else { return cfg };
    if let Some(v) = user["collapsed_rows"].as_f64() {
        cfg.collapsed_rows = v;
    }
    if let Some(v) = user["collapsed_cols"].as_f64() {
        cfg.collapsed_cols = v;
    }
    if let Some(v) = user["skip_root"].as_bool() {
        cfg.skip_root = v;
    }
    cfg
}

fn state_path(name: &str) -> PathBuf {
    env::var_os("HERDR_PLUGIN_STATE_DIR").map(PathBuf::from).unwrap_or_else(env::temp_dir).join(name)
}

fn load_disabled_tabs() -> BTreeSet<String> {
    fs::read_to_string(state_path("disabled-tabs.json"))
        .ok()
        .and_then(|text| serde_json::from_str(&text).ok())
        .unwrap_or_default()
}

fn save_disabled_tabs(tabs: &BTreeSet<String>) -> Result<(), String> {
    let text = serde_json::to_string(tabs).map_err(|e| e.to_string())?;
    fs::write(state_path("disabled-tabs.json"), text).map_err(|e| format!("save disabled tabs: {e}"))
}
