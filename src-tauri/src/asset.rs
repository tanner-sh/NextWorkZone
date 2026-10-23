//! `nextworkzone://` 协议：让 WebView 能显示需要认证的图片（Jira 附件、Wiki 内嵌图片、头像等）。
//!
//! 工作空间里的图片（`nextworkzone://localhost/ws/<id>`）直接从本地数据库读取，
//! 剪贴板历史中的图片（`nextworkzone://localhost/clip/...`）从本机文件读取。
//!
//! 前端把 `<img src>` 改写为 `nextworkzone://localhost/<service>/<编码后的路径或完整地址>`，
//! 这里带上对应系统的凭据去取回内容。只允许访问已配置系统的地址，避免凭据被发往其他主机。

use nextworkzone_core::{Error, Result, Service};
use percent_encoding::percent_decode_str;
use tauri::http::{Request, Response, StatusCode, header};
use tauri::{Manager, UriSchemeContext, UriSchemeResponder};

use crate::state::AppState;

pub fn handle<R: tauri::Runtime>(
    ctx: UriSchemeContext<'_, R>,
    request: Request<Vec<u8>>,
    responder: UriSchemeResponder,
) {
    let app = ctx.app_handle().clone();
    let path = request.uri().path().to_string();
    tauri::async_runtime::spawn(async move {
        let response = match fetch(&app, &path).await {
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

async fn fetch<R: tauri::Runtime>(app: &tauri::AppHandle<R>, path: &str) -> Result<(Vec<u8>, Option<String>)> {
    let state = app.state::<AppState>().inner();
    let (service, target) = path
        .trim_start_matches('/')
        .split_once('/')
        .ok_or_else(|| Error::InvalidUrl(path.to_string()))?;
    let service = match service {
        // 工作空间里的图片：nextworkzone://localhost/ws/<图片 id>
        "ws" => {
            let id = percent_decode_str(target).decode_utf8_lossy().into_owned();
            let workspace = state.workspace.clone();
            let found = tauri::async_runtime::spawn_blocking(move || workspace.asset(&id))
                .await
                .map_err(|e| Error::Other(e.to_string()))??;
            return found
                .map(|(mime, data)| (data, Some(mime)))
                .ok_or_else(|| Error::Other("图片尚未同步到本机".into()));
        }
        // 剪贴板历史中的图片：nextworkzone://localhost/clip/<thumb|image|icon>/<id>
        "clip" => {
            let (kind, id) = target.split_once('/').ok_or_else(|| Error::InvalidUrl(path.to_string()))?;
            let id = percent_decode_str(id).decode_utf8_lossy().into_owned();
            let clip = app.state::<crate::clipboard::Clip>();
            let file = match kind {
                "thumb" => clip.store.thumb_path(&id),
                "image" => clip.store.image_path(&id),
                "icon" => clip.store.icon_path(&id),
                _ => return Err(Error::InvalidUrl(path.to_string())),
            };
            let data = tokio::fs::read(file).await?;
            return Ok((data, Some("image/png".into())));
        }
        "jira" => Service::Jira,
        "confluence" => Service::Confluence,
        "gitlab" => Service::Gitlab,
        _ => return Err(Error::InvalidUrl(path.to_string())),
    };
    let target = percent_decode_str(target).decode_utf8_lossy().into_owned();
    let url = state.resolve_url(service, &target)?;
    state.fetch_web(service, &url).await
}
