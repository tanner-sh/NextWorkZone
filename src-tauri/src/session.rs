//! 网页登录窗口：用户在应用内完成认证后，取出会话 Cookie 交给应用层验证并保存。

use std::sync::Arc;

use nextworkzone_app::AppState;
use nextworkzone_app::commands::session::{web_login_finish, web_login_info};
use nextworkzone_core::{Error, Result, Service};
use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Manager, State, Url, WebviewUrl, WebviewWindowBuilder};

/// 打开登录窗口。登录完成后窗口自动关闭，并发出会话变化事件。
#[tauri::command]
pub async fn web_login(app: AppHandle, state: State<'_, Arc<AppState>>, service: Service) -> Result<()> {
    let info = web_login_info(&state, service).await?;
    let label = format!("login-{}", service.key());
    if let Some(window) = app.get_webview_window(&label) {
        let _ = window.set_focus();
        return Ok(());
    }
    let url: Url = info.url.parse().map_err(|_| Error::InvalidUrl(info.url.clone()))?;
    let base: Url = info.base_url.parse().map_err(|_| Error::InvalidUrl(info.base_url.clone()))?;

    let mut builder = WebviewWindowBuilder::new(&app, &label, WebviewUrl::External(url)).title(&info.title).inner_size(960.0, 760.0);
    if let Some(script) = &info.autofill {
        builder = builder.initialization_script(script);
    }
    let state = state.inner().clone();
    builder
        .on_page_load(move |window, payload| {
            if payload.event() != PageLoadEvent::Finished {
                return;
            }
            let (state, base, current) = (state.clone(), base.clone(), payload.url().to_string());
            // 读取 Cookie 不能在页面加载回调里同步进行
            tauri::async_runtime::spawn(async move {
                let Ok(cookies) = window.cookies_for_url(base) else { return };
                let header = cookies.iter().map(|c| format!("{}={}", c.name(), c.value())).collect::<Vec<_>>().join("; ");
                if web_login_finish(&state, service, current, header).await.unwrap_or(false) {
                    let _ = window.close();
                }
            });
        })
        .build()
        .map_err(|e| Error::Other(format!("无法打开登录窗口：{e}")))?;
    Ok(())
}
