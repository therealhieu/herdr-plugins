//! Minimal Herdr socket API client.
//!
//! The server reads one newline-delimited JSON request per connection and
//! answers with one JSON line. Unix uses a Unix domain socket; Windows uses a
//! named pipe, which std can open as a file.

use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};

pub struct Api {
    path: String,
    seq: u32,
}

impl Api {
    pub fn new(path: String) -> Self {
        Self { path, seq: 0 }
    }

    pub fn call(&mut self, method: &str, params: Value) -> Result<Value, String> {
        self.seq += 1;
        let request = json!({ "id": format!("stack-{}", self.seq), "method": method, "params": params });
        let mut line = request.to_string();
        line.push('\n');

        let mut conn = connect(&self.path).map_err(|e| format!("connect {}: {e}", self.path))?;
        conn.write_all(line.as_bytes()).map_err(|e| format!("{method}: write: {e}"))?;
        conn.flush().map_err(|e| format!("{method}: flush: {e}"))?;

        let mut reply = String::new();
        BufReader::new(conn)
            .read_line(&mut reply)
            .map_err(|e| format!("{method}: read: {e}"))?;
        let mut response: Value =
            serde_json::from_str(&reply).map_err(|e| format!("{method}: bad response: {e}"))?;

        if let Some(error) = response.get("error") {
            return Err(format!("{method}: {error}"));
        }
        Ok(response["result"].take())
    }
}

#[cfg(unix)]
fn connect(path: &str) -> std::io::Result<std::os::unix::net::UnixStream> {
    std::os::unix::net::UnixStream::connect(path)
}

#[cfg(windows)]
fn connect(path: &str) -> std::io::Result<std::fs::File> {
    std::fs::OpenOptions::new().read(true).write(true).open(path)
}
