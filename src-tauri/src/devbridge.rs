//! 本机测试通道（只在开发构建中启动）。在主窗口中执行一段 JS 并取回结果，用于自动化验证界面
//! （例如点击按钮、读取表单状态），不依赖屏幕点击。
//!
//! 只监听 127.0.0.1，请求需携带令牌（启动时写入应用缓存目录下的 `devbridge.token`）：
//!
//! ```sh
//! curl -s -H "x-token: $(cat ~/Library/Caches/com.nextworkzone.desktop/devbridge.token)" \
//!      --data 'return document.title' http://127.0.0.1:17890/eval
//! ```
//!
//! 请求体是异步函数体，用 `return` 返回值；结果以 JSON 返回。默认在主窗口执行，
//! 请求头 `x-window: <窗口 label>` 可以指定其他窗口。

use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tauri::{AppHandle, Manager};

const ADDR: &str = "127.0.0.1:17890";

#[derive(Default)]
pub struct Pending(Mutex<HashMap<u64, Sender<String>>>);

/// 页面执行完脚本后回传结果。
#[tauri::command]
pub fn dev_eval_result(app: AppHandle, id: u64, result: String) {
    if let Some(pending) = app.try_state::<Arc<Pending>>()
        && let Some(tx) = pending.0.lock().unwrap().remove(&id)
    {
        let _ = tx.send(result);
    }
}

pub fn start(app: &AppHandle) {
    let Ok(dir) = app.path().app_cache_dir() else { return };
    let token = format!("{:x}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos() ^ std::process::id() as u128);
    let _ = std::fs::create_dir_all(&dir);
    if std::fs::write(dir.join("devbridge.token"), &token).is_err() {
        return;
    }
    let Ok(listener) = TcpListener::bind(ADDR) else { return };
    let pending = Arc::new(Pending::default());
    app.manage(pending.clone());
    let app = app.clone();
    std::thread::spawn(move || {
        for (index, stream) in listener.incoming().flatten().enumerate() {
            let (app, pending, token) = (app.clone(), pending.clone(), token.clone());
            let id = index as u64 + 1;
            std::thread::spawn(move || handle(stream, &app, &pending, &token, id));
        }
    });
}

fn handle(mut stream: TcpStream, app: &AppHandle, pending: &Pending, token: &str, id: u64) {
    let _ = stream.set_read_timeout(Some(Duration::from_secs(10)));
    let Some((headers, body)) = read_request(&mut stream) else { return };
    let authorized = headers.lines().any(|l| {
        l.split_once(':').is_some_and(|(k, v)| k.trim().eq_ignore_ascii_case("x-token") && v.trim() == token)
    });
    if !authorized {
        respond(&mut stream, 403, "forbidden");
        return;
    }
    // 默认在主窗口执行；请求头 `x-window: <窗口 label>` 可以指定其他窗口（例如 clipboard）
    let label = headers
        .lines()
        .find_map(|l| l.split_once(':').filter(|(k, _)| k.trim().eq_ignore_ascii_case("x-window")).map(|(_, v)| v.trim().to_string()))
        .unwrap_or_else(|| "main".into());
    let Some(window) = app.get_webview_window(&label) else {
        respond(&mut stream, 500, "no window");
        return;
    };
    let (tx, rx) = channel();
    pending.0.lock().unwrap().insert(id, tx);
    let script = format!(
        r#"(async () => {{
  let result;
  try {{ result = {{ ok: true, value: await (async () => {{ {body} }})() }}; }}
  catch (e) {{ result = {{ ok: false, error: String(e && e.stack || e) }}; }}
  let text; try {{ text = JSON.stringify(result); }} catch (e) {{ text = JSON.stringify({{ ok: false, error: "结果无法序列化" }}); }}
  window.__TAURI_INTERNALS__.invoke("dev_eval_result", {{ id: {id}, result: text }});
}})();"#
    );
    if window.eval(&script).is_err() {
        respond(&mut stream, 500, "eval failed");
        return;
    }
    match rx.recv_timeout(Duration::from_secs(60)) {
        Ok(result) => respond(&mut stream, 200, &result),
        Err(_) => {
            pending.0.lock().unwrap().remove(&id);
            respond(&mut stream, 504, "timeout");
        }
    }
}

fn read_request(stream: &mut TcpStream) -> Option<(String, String)> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    let header_end = loop {
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(pos) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break pos + 4;
        }
    };
    let headers = String::from_utf8_lossy(&buf[..header_end]).into_owned();
    let length: usize = headers
        .lines()
        .find_map(|l| l.split_once(':').filter(|(k, _)| k.trim().eq_ignore_ascii_case("content-length")).map(|(_, v)| v.trim().parse().unwrap_or(0)))
        .unwrap_or(0);
    while buf.len() < header_end + length {
        let n = stream.read(&mut chunk).ok()?;
        if n == 0 {
            break;
        }
        buf.extend_from_slice(&chunk[..n]);
    }
    let body = String::from_utf8_lossy(&buf[header_end..]).into_owned();
    Some((headers, body))
}

fn respond(stream: &mut TcpStream, status: u16, body: &str) {
    let _ = write!(
        stream,
        "HTTP/1.1 {status} OK\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
}
