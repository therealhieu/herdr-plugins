//! Layout tree and the stacking plan.
//!
//! A tab layout is a BSP tree (`layout.export`). A split's path is a list of
//! booleans from the root: `false` = first child, `true` = second child, the
//! same encoding `layout.set_split_ratio` expects.

use serde_json::Value;

/// Herdr clamps split ratios to this range.
pub const MIN_RATIO: f64 = 0.1;
pub const MAX_RATIO: f64 = 0.9;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Axis {
    /// Children stacked top/bottom; sized by rows.
    Down,
    /// Children side by side; sized by columns.
    Right,
}

#[derive(Debug)]
pub enum Node {
    Pane(String),
    Split {
        axis: Axis,
        ratio: f64,
        first: Box<Node>,
        second: Box<Node>,
    },
}

impl Node {
    pub fn from_json(value: &Value) -> Result<Node, String> {
        match value["type"].as_str() {
            Some("pane") => Ok(Node::Pane(value["pane_id"].as_str().unwrap_or_default().to_string())),
            Some("split") => {
                let axis = match value["direction"].as_str() {
                    Some("down") => Axis::Down,
                    Some("right") => Axis::Right,
                    other => return Err(format!("unknown split direction {other:?}")),
                };
                Ok(Node::Split {
                    axis,
                    ratio: value["ratio"].as_f64().ok_or("split without ratio")?,
                    first: Box::new(Node::from_json(&value["first"])?),
                    second: Box::new(Node::from_json(&value["second"])?),
                })
            }
            other => Err(format!("unknown layout node {other:?}")),
        }
    }

    /// Path to the pane with `pane_id`, if it is in this tree.
    pub fn find_path(&self, pane_id: &str) -> Option<Vec<bool>> {
        match self {
            Node::Pane(id) => (id == pane_id).then(Vec::new),
            Node::Split { first, second, .. } => {
                for (step, child) in [(false, first), (true, second)] {
                    if let Some(mut rest) = child.find_path(pane_id) {
                        rest.insert(0, step);
                        return Some(rest);
                    }
                }
                None
            }
        }
    }

    /// How many collapsed strips this subtree needs along `axis`.
    fn span(&self, axis: Axis) -> u32 {
        match self {
            Node::Pane(_) => 1,
            Node::Split { axis: own, first, second, .. } => {
                let (a, b) = (first.span(axis), second.span(axis));
                if *own == axis { a + b } else { a.max(b) }
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct Config {
    /// Height of a collapsed pane in a stacked (down) split.
    pub collapsed_rows: f64,
    /// Width of a collapsed pane in a side-by-side (right) split.
    pub collapsed_cols: f64,
    /// Never resize the tab's top split.
    pub skip_root: bool,
}

impl Default for Config {
    fn default() -> Self {
        Self { collapsed_rows: 3.0, collapsed_cols: 20.0, skip_root: true }
    }
}

/// A split ratio change: (path to the split, new ratio).
pub type Update = (Vec<bool>, f64);

/// Compute the ratio changes that expand the pane at `target` and collapse its
/// siblings. `rows`/`cols` are the tab's size.
pub fn plan(root: &Node, target: &[bool], rows: f64, cols: f64, cfg: &Config) -> Vec<Update> {
    let mut updates = Vec::new();
    let mut path = Vec::new();
    walk(root, Size { rows, cols }, &mut path, target, cfg, false, &mut updates);
    updates
}

#[derive(Clone, Copy)]
struct Size {
    rows: f64,
    cols: f64,
}

impl Size {
    fn along(&self, axis: Axis) -> f64 {
        match axis {
            Axis::Down => self.rows,
            Axis::Right => self.cols,
        }
    }

    fn with(mut self, axis: Axis, value: f64) -> Size {
        match axis {
            Axis::Down => self.rows = value,
            Axis::Right => self.cols = value,
        }
        self
    }
}

/// `collapsed` marks a subtree squeezed into strips beside the focused pane.
fn walk(
    node: &Node,
    size: Size,
    path: &mut Vec<bool>,
    target: &[bool],
    cfg: &Config,
    collapsed: bool,
    out: &mut Vec<Update>,
) {
    let Node::Split { axis, ratio: current, first, second } = node else {
        return;
    };
    let axis = *axis;
    let total = size.along(axis);
    let depth = path.len();
    let on_path = target.len() > depth && target[..depth] == path[..];
    let is_skipped_root = depth == 0 && cfg.skip_root;
    let unit = match axis {
        Axis::Down => cfg.collapsed_rows,
        Axis::Right => cfg.collapsed_cols,
    };

    let ratio = if on_path && !is_skipped_root {
        // The focused side gets everything except the strips for the other side.
        let focused_second = target[depth];
        let other = if focused_second { first } else { second };
        let other_size = unit * f64::from(other.span(axis));
        let focused_share = if total > 0.0 { 1.0 - other_size / total } else { 0.5 };
        if focused_second { 1.0 - focused_share } else { focused_share }
    } else if collapsed {
        // Inside a collapsed region: share space by strip count so bars are even.
        let (a, b) = (f64::from(first.span(axis)), f64::from(second.span(axis)));
        a / (a + b)
    } else {
        *current // unrelated part of the tab, or the skipped root: leave it alone
    };
    let ratio = ratio.clamp(MIN_RATIO, MAX_RATIO);
    if (ratio - current).abs() > 1e-3 {
        out.push((path.clone(), ratio));
    }

    let accordion = on_path && !is_skipped_root;
    let first_len = total * ratio;
    for (step, child, len) in [(false, first, first_len), (true, second, total - first_len)] {
        let child_on_path = on_path && target[depth] == step;
        path.push(step);
        walk(child, size.with(axis, len), path, target, cfg, collapsed || (accordion && !child_on_path), out);
        path.pop();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn pane(id: &str) -> Value {
        json!({ "type": "pane", "pane_id": id })
    }

    fn split(direction: &str, ratio: f64, first: Value, second: Value) -> Value {
        json!({ "type": "split", "direction": direction, "ratio": ratio, "first": first, "second": second })
    }

    /// Left half: a / b / c stacked. Right half: r1 / r2 stacked (ratio 0.7).
    fn two_columns() -> Node {
        let left = split("down", 0.5, pane("a"), split("down", 0.5, pane("b"), pane("c")));
        let right = split("down", 0.7, pane("r1"), pane("r2"));
        Node::from_json(&split("right", 0.5, left, right)).unwrap()
    }

    fn plan_for(root: &Node, pane_id: &str) -> Vec<Update> {
        let target = root.find_path(pane_id).unwrap();
        plan(root, &target, 40.0, 120.0, &Config::default())
    }

    #[test]
    fn finds_paths() {
        let root = two_columns();
        assert_eq!(root.find_path("a"), Some(vec![false, false]));
        assert_eq!(root.find_path("c"), Some(vec![false, true, true]));
        assert_eq!(root.find_path("r2"), Some(vec![true, true]));
        assert_eq!(root.find_path("missing"), None);
    }

    #[test]
    fn expands_first_pane_and_leaves_root_and_other_half() {
        let updates = plan_for(&two_columns(), "a");
        // a gets 40 - 2 strips * 3 rows = 34 rows; the b/c split is already even.
        assert_eq!(updates.len(), 1);
        assert_eq!(updates[0].0, vec![false]);
        assert!((updates[0].1 - 34.0 / 40.0).abs() < 1e-9);
    }

    #[test]
    fn expands_middle_pane() {
        let updates = plan_for(&two_columns(), "b");
        // Outer left split: a collapses to 3 of 40 rows -> clamped to 0.1.
        assert_eq!(updates[0], (vec![false], MIN_RATIO));
        // Inner split (36 rows): b wants 33/36 = 0.917, clamped to 0.9.
        assert_eq!(updates[1], (vec![false, true], MAX_RATIO));
    }

    #[test]
    fn stacks_second_half_independently() {
        let updates = plan_for(&two_columns(), "r2");
        assert_eq!(updates, vec![(vec![true], MIN_RATIO)]);
    }

    #[test]
    fn whole_tab_when_root_not_skipped() {
        let root = two_columns();
        let target = root.find_path("a").unwrap();
        let cfg = Config { skip_root: false, ..Config::default() };
        let updates = plan(&root, &target, 40.0, 120.0, &cfg);
        // Right half collapses to one 20-column strip: 100 / 120.
        assert_eq!(updates[0].0, Vec::<bool>::new());
        assert!((updates[0].1 - 100.0 / 120.0).abs() < 1e-9);
    }

    #[test]
    fn single_pane_tab_needs_nothing() {
        let root = Node::from_json(&pane("solo")).unwrap();
        assert!(plan_for(&root, "solo").is_empty());
    }
}
