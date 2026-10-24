//! `nextworkzone://` 协议：让 WebView 能显示需要认证的图片（Jira 附件、Wiki 内嵌图片、头像等）。
//!
//! 前端把 `<img src>` 改写为 `nextworkzone://localhost/<路径>`，路径格式见 [`nextworkzone_app::asset`]。

use std::sync::Arc;

use nextworkzone_app::AppState;
use nextworkzone_core::Error;
use tauri::http::{Request, Response, StatusCode, header};
use tauri::{Manager, UriSchemeContext, UriSchemeResponder};

pub fn handle<R: tauri::Runtime>(
    ctx: UriSchemeContext<'_, R>,
    request: Request<Vec<u8>>,
    responder: UriSchemeResponder,
) {
    let state = ctx.app_handle().state::<Arc<AppState>>().inner().clone();
    let path = request.uri().path().to_string();
    tauri::async_runtime::spawn(async move {
        let response = match nextworkzone_app::asset::fetch(&state, &path).await {
            Ok((bytes, content_type)) => Response::builder()
                .status(StatusCode::OK)
                .header(header::CONTENT_TYPE, content_type.unwrap_or_else(|| "application/octet-stream".into()))
                .header(header::CACHE_CONTROL, "private, max-age=86400")
                .body(bytes),
            Err(e) => Response::builder()
                .status(match e {
                    Error::SessionRequired(_) | Error::Unauthorized { .. } => StatusCode::UNAUTHORIZED,
                    _ => StatusCode::BAD_GATEWAY,
                })
                .header(header::CONTENT_TYPE, "text/plain; charset=utf-8")
                .body(e.to_string().into_bytes()),
        };
        responder.respond(response.expect("响应头均为合法值"));
    });
}
