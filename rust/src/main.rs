//! Rust stdio MCP transport for the Hermes <-> opencode/kilocode tool bridge.
//!
//! opencode/kilocode spawn THIS binary as the `hermes-tools` MCP server. It speaks
//! the MCP stdio wire protocol (newline-delimited JSON-RPC 2.0 over stdio, UTF-8)
//! and forwards `tools/list` / `tools/call` to a shared warm Python worker
//! (`agent.transports.hermes_tools_worker`) over a Unix socket. The worker holds
//! the expensive Hermes imports (~1.5 s) and ~115 MB resident footprint, paid once
//! per host instead of once per spawned client process.
//!
//! The response shapes mirror the `mcp` 2.x Python SDK (`MCPServer`): a tool's
//! string return becomes `content:[{type:"text",text:<str>}]`; SDK-level tool
//! exceptions become `isError:true`. The Python wrapper already converts tool
//! exceptions into JSON error strings, so the common path never sets `isError`.
//!
//! Usage:
//!   hermes-tools-mcp --socket <worker.sock> \
//!       [--worker-python <venv>/bin/python] [--worker-module <module>] \
//!       [--cwd <hermes-agent dir>] [--idle-seconds <n>]

use std::env;
use std::io::{self, BufRead, BufReader, BufWriter, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{json, Value};

// Keep stdout writes under a mutex so logging (stderr) and protocol (stdout)
// never race even if a helper thread emits something.
const MCP_NAME: &str = "hermes-tools";
const MCP_VERSION: &str = "0.1.0";
const PROTOCOL_VERSIONS: &[&str] = &["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];

struct Config {
    socket: PathBuf,
    worker_python: PathBuf,
    worker_module: String,
    cwd: PathBuf,
    idle_seconds: u64,
    verbose: bool,
    max_wait_ms: u64,
}

fn parse_args() -> Config {
    let mut socket: Option<PathBuf> = None;
    let mut worker_python: Option<PathBuf> = None;
    let mut worker_module = "agent.transports.hermes_tools_worker".to_string();
    let mut cwd: Option<PathBuf> = None;
    let mut idle_seconds: u64 = 300;
    let mut verbose = false;
    let mut max_wait_ms: u64 = 10_000;

    let args: Vec<String> = env::args().skip(1).collect();
    let mut i = 0;
    while i < args.len() {
        let a = &args[i];
        let v = |i: &mut usize| -> Option<String> {
            *i += 1;
            args.get(*i).cloned()
        };
        match a.as_str() {
            "--socket" => socket = v(&mut i).map(PathBuf::from),
            "--worker-python" => worker_python = v(&mut i).map(PathBuf::from),
            "--worker-module" => worker_module = v(&mut i).unwrap_or(worker_module),
            "--cwd" => cwd = v(&mut i).map(PathBuf::from),
            "--idle-seconds" => idle_seconds = v(&mut i).and_then(|s| s.parse().ok()).unwrap_or(300),
            "--max-wait-ms" => max_wait_ms = v(&mut i).and_then(|s| s.parse().ok()).unwrap_or(10_000),
            "--verbose" | "-v" => verbose = true,
            other => {
                eprintln!("hermes-tools-mcp: ignoring unknown arg {other:?}");
            }
        }
        i += 1;
    }

    let cwd = cwd.unwrap_or_else(|| env::current_dir().unwrap_or_else(|_| PathBuf::from(".")));
    let worker_python = worker_python.unwrap_or_else(|| cwd.join("venv/bin/python"));
    let worker_python = {
        let p = worker_python;
        if p.is_absolute() {
            p
        } else {
            let joined = cwd.join(&p);
            if joined.exists() {
                joined
            } else {
                p
            }
        }
    };

    Config {
        socket: socket.expect("--socket is required"),
        worker_python,
        worker_module,
        cwd,
        idle_seconds,
        verbose,
        max_wait_ms,
    }
}

// ---------------------------------------------------------------------------
// Worker lifecycle + RPC
// ---------------------------------------------------------------------------

fn lock(path: &Path) -> Result<UnixStream, io::Error> {
    // Capture TCP_CORK-free std client connect; symlink/perm errors propagate.
    UnixStream::connect(path)
}

fn rpc(socket: &Path, payload: Value) -> Result<Value, io::Error> {
    let stream = UnixStream::connect(socket)?;
    stream.set_read_timeout(Some(Duration::from_secs(300)))?;
    let mut writer = BufWriter::new(stream.try_clone()?);
    writer.write_all((payload.to_string() + "\n").as_bytes())?;
    writer.flush()?;
    let mut line = String::new();
    let mut reader = BufReader::new(stream);
    reader.read_line(&mut line)?;
    if line.trim().is_empty() {
        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "empty worker response"));
    }
    serde_json::from_str(&line).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, format!("bad worker JSON: {e}")))
}

fn worker_alive(socket: &Path) -> bool {
    match UnixStream::connect(socket) {
        Ok(_) => true,
        Err(_) => false,
    }
}

/// Worker stderr goes to `<socket>.log` (append) so the worker never inherits
/// the parent process's pipes (an orphaned worker would otherwise hold the MCP
/// server's stderr/stdout open) while still keeping diagnostics on disk.
fn worker_stderr(socket: &Path) -> Stdio {
    let mut log = socket.as_os_str().to_owned();
    log.push(".log");
    match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .truncate(false)
        .open(&log)
    {
        Ok(f) => Stdio::from(f),
        Err(_) => Stdio::null(),
    }
}

/// Spawn the warm Python worker if the socket is not reachable; wait up to
/// `cfg.max_wait_ms` for it to come up. Returns a handle only when spawned.
fn ensure_worker(cfg: &Config) -> Result<Option<Child>, String> {
    if worker_alive(&cfg.socket) {
        return Ok(None);
    }
    if cfg.verbose {
        eprintln!("hermes-tools-mcp: worker socket {} not reachable; spawning", cfg.socket.display());
    }
    // Remove a stale socket file so the worker can bind (worker unlinks on exit; a
    // crashed worker leaves the file behind).
    let _ = std::fs::remove_file(&cfg.socket);

    let mut worker = Command::new(&cfg.worker_python)
        .arg("-m")
        .arg(&cfg.worker_module)
        .arg("--socket")
        .arg(&cfg.socket)
        .arg("--idle-seconds")
        .arg(cfg.idle_seconds.to_string())
        .current_dir(&cfg.cwd)
        .env("HERMES_QUIET", "1")
        .env("HERMES_REDACT_SECRETS", "true")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(worker_stderr(&cfg.socket))
        .spawn()
        .map_err(|e| format!("cannot spawn worker {}: {e}", cfg.worker_python.display()))?;

    if cfg.verbose {
        eprintln!("hermes-tools-mcp: worker pid={}", worker.id());
    }

    let deadline = Instant::now() + Duration::from_millis(cfg.max_wait_ms);
    loop {
        match lock(&cfg.socket) {
            Ok(_) => return Ok(Some(worker)),
            Err(_) => {
                if Instant::now() >= deadline {
                    return Err(format!(
                        "worker did not bind {} within {} ms",
                        cfg.socket.display(),
                        cfg.max_wait_ms
                    ));
                }
                // If the child exited, fail fast with its status.
                match worker.try_wait() {
                    Ok(Some(status)) => {
                        return Err(format!("worker exited early with status: {status}"));
                    }
                    Ok(None) => {}
                    Err(e) => return Err(format!("worker wait failed: {e}")),
                }
                thread::sleep(Duration::from_millis(25));
            }
        }
    }
}

/// Forward a request to the worker; returns its full JSON-RPC response.
fn forward(cfg: &Config, req: &Value) -> Result<Value, String> {
    let id = req.get("id").cloned().unwrap_or(Value::Null);
    let method = req
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or("tools/list");
    let params = req.get("params").cloned().unwrap_or_else(|| json!({}));

    let payload = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
        "params": params,
    });

    match rpc(&cfg.socket, payload.clone()) {
        Ok(resp) => Ok(resp),
        Err(e) => {
            // Worker may have gone idle and exited (shared process). Try to
            // respawn once, then re-issue.
            if cfg.verbose {
                eprintln!("hermes-tools-mcp: worker RPC failed: {e}; respawning");
            }
            match ensure_worker(cfg) {
                Ok(_) => rpc(&cfg.socket, payload).map_err(|e| format!("worker still unreachable: {e}")),
                Err(spawn_err) => Err(format!("{spawn_err}")),
            }
        }
    }
}

// ---------------------------------------------------------------------------
// MCP protocol handlers
// ---------------------------------------------------------------------------

fn negotiate_version(client: Option<&Value>) -> String {
    let requested = client.and_then(|v| v.as_str()).unwrap_or("");
    if PROTOCOL_VERSIONS.contains(&requested) {
        requested.to_string()
    } else {
        "2025-06-18".to_string()
    }
}

fn handle_initialize(req: &Value) -> Value {
    let params = req.get("params").unwrap_or(&Value::Null);
    let requested = params.get("protocolVersion");
    let version = negotiate_version(requested);
    json!({
        "jsonrpc": "2.0",
        "id": req.get("id").cloned().unwrap_or(Value::Null),
        "result": {
            "protocolVersion": version,
            "capabilities": { "tools": {} },
            "serverInfo": { "name": MCP_NAME, "version": MCP_VERSION },
            "instructions": (
                concat!(
                    "Hermes Agent's tool surface, exposed for use inside an opencode/kilocode ",
                    "session. Use these for capabilities the client's built-in toolset doesn't ",
                    "cover: web search/extract, browser automation, vision, image generation, ",
                    "persistent memory, skills, and cross-session search."
                )
            ),
        }
    })
}

fn handle_ping(req: &Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": req.get("id").cloned().unwrap_or(Value::Null),
        "result": {}
    })
}

/// tools/list -> passthrough of the worker's catalog.
fn handle_tools_list(cfg: &Config, req: &Value) -> Value {
    let id = req.get("id").cloned().unwrap_or(Value::Null);
    match forward(cfg, req) {
        Ok(resp) => {
            if let Some(result) = resp.get("result").cloned() {
                // MCP 2.x ListToolsResult: {tools: [...]}. Pass through verbatim.
                json!({ "jsonrpc": "2.0", "id": id, "result": result })
            } else {
                // Worker surfaced a JSON-RPC error: propagate it.
                let mut out = json!({ "jsonrpc": "2.0", "id": id });
                if let Some(err) = resp.get("error") {
                    out["error"] = err.clone();
                }
                out
            }
        }
        Err(e) => {
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32000, "message": format!("worker unreachable: {e}") }
            })
        }
    }
}

/// tools/call -> worker returns {result:{text: <string>}}; wrap in MCP content.
fn handle_tools_call(cfg: &Config, req: &Value) -> Value {
    let id = req.get("id").cloned().unwrap_or(Value::Null);
    match forward(cfg, req) {
        Ok(resp) => {
            if let Some(text) = resp
                .get("result")
                .and_then(|r| r.get("text"))
                .and_then(Value::as_str)
            {
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": { "content": [ { "type": "text", "text": text } ] }
                })
            } else if let Some(err) = resp.get("error") {
                let msg = err.get("message").and_then(Value::as_str).unwrap_or("worker error");
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "content": [ { "type": "text", "text": format!("hermes-tools error: {msg}") } ],
                        "isError": true
                    }
                })
            } else {
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": { "code": -32603, "message": "malformed worker response: missing result.text" }
                })
            }
        }
        Err(e) => {
            json!({
                "jsonrpc": "2.0",
                "id": id,
                "result": {
                    "content": [ { "type": "text", "text": format!("hermes-tools unavailable: {e}") } ],
                    "isError": true
                }
            })
        }
    }
}

fn method_not_found(req: &Value, msg: &str) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": req.get("id").cloned().unwrap_or(Value::Null),
        "error": { "code": -32601, "message": msg }
    })
}

fn parse_error(id: Value) -> Value {
    json!({
        "jsonrpc": "2.0",
        "id": id,
        "error": { "code": -32700, "message": "parse error" }
    })
}

// ---------------------------------------------------------------------------
// main loop
// ---------------------------------------------------------------------------

fn main() {
    let cfg = parse_args();

    match ensure_worker(&cfg) {
        Ok(_) => {}
        Err(e) => {
            eprintln!("hermes-tools-mcp: {e}");
            // Keep trying in the background: a transient failure at client startup
            // (e.g. worker mid-warm-up, socket race) shouldn't kill the session.
            if !cfg.verbose {
                let cfg_clone_respawn = Config {
                    socket: cfg.socket.clone(),
                    worker_python: cfg.worker_python.clone(),
                    worker_module: cfg.worker_module.clone(),
                    cwd: cfg.cwd.clone(),
                    idle_seconds: cfg.idle_seconds,
                    verbose: cfg.verbose,
                    max_wait_ms: cfg.max_wait_ms,
                };
                thread::spawn(move || {
                    thread::sleep(Duration::from_millis(500));
                    let retries = cfg_clone_respawn.max_wait_ms / 500;
                    for _ in 0..retries.max(2) {
                        if worker_alive(&cfg_clone_respawn.socket) {
                            return;
                        }
                        thread::sleep(Duration::from_millis(500));
                    }
                    let _ = ensure_worker(&cfg_clone_respawn);
                });
            }
        }
    }

    run_stdio_loop(&cfg);
}

fn run_stdio_loop(cfg: &Config) {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut writer = BufWriter::new(stdout.lock());
    let reader = BufReader::new(stdin.lock());

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let parsed: Result<Value, _> = serde_json::from_str(trimmed);
        let response: Option<Value> = match parsed {
            Err(_) => Some(parse_error(Value::Null)),
            Ok(msg) if msg.is_object() => dispatch(cfg, &msg),
            Ok(array) if array.is_array() => Some(parse_error(Value::Null)), // batches unsupported
            Ok(_) => None,
        };
        if let Some(resp) = response {
            let s = resp.to_string();
            if writer.write_all(s.as_bytes()).is_err() || writer.write_all(b"\n").is_err() {
                break;
            }
            if writer.flush().is_err() {
                break;
            }
        }
    }
}

fn dispatch(cfg: &Config, msg: &Value) -> Option<Value> {
    let has_id = msg.get("id").map_or(false, |v| !v.is_null());
    // Notifications carry no id and expect no response.
    if !has_id {
        return None;
    }
    let method = match msg.get("method").and_then(Value::as_str) {
        Some(m) if !m.is_empty() => m,
        _ => return Some(parse_error(msg.get("id").cloned().unwrap_or(Value::Null))),
    };

    match method {
        "initialize" => Some(handle_initialize(msg)),
        "ping" => Some(handle_ping(msg)),
        "tools/list" => Some(handle_tools_list(cfg, msg)),
        "tools/call" => Some(handle_tools_call(cfg, msg)),
        "logging/setLevel" => Some(handle_ping(msg)), // accept-only, no-op
        other => Some(method_not_found(msg, &format!("Method not found: {other}"))),
    }
}