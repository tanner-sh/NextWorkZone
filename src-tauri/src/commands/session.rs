//! 网页登录：附件、图片等网页路径不走 REST API，部分部署（例如启用了 2FA / SSO 插件）不接受 Token。
//! 这种情况下在应用内打开登录窗口，用户照常完成认证后，取出会话 Cookie 供下载附件、图片使用。
//!
//! - 先用 Token 探测网页路径；能访问的部署不需要网页登录。
//! - 配置了网页登录账号时，登录窗口会自动填写账号密码并提交，用户只需完成额外的验证步骤。
//! - 后台定期用会话访问一次受保护页面（[`keep_alive_loop`]），让会话保持活跃。

use std::collections::HashMap;
use std::time::Duration;

use nextworkzone_core::secrets::Secret;
use nextworkzone_core::{Error, Result, Service, http};
use serde::Serialize;
use tauri::webview::PageLoadEvent;
use tauri::{AppHandle, Emitter, Manager, State, Url, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use crate::state::AppState;

/// 网页会话状态变化（登录成功、会话失效）时发给前端的事件，载荷为服务名。
pub const SESSION_EVENT: &str = "web-session";

/// 会话保活的间隔。
const KEEP_ALIVE_INTERVAL: Duration = Duration::from_secs(10 * 60);

/// 支持网页登录的系统（Atlassian 系的标准登录页）。
pub const WEB_SERVICES: [Service; 2] = [Service::Jira, Service::Confluence];

/// 登录页地址。
fn login_path(service: Service) -> Result<&'static str> {
    match service {
        Service::Jira => Ok("/login.jsp?os_destination=%2Fsecure%2FViewProfile.jspa"),
        Service::Confluence => Ok("/login.action?os_destination=%2Fusers%2Fviewmyprofile.action"),
        Service::Gitlab => Err(Error::Other("GitLab 不需要网页登录".into())),
    }
}

/// 需要登录才能访问的网页（不是 REST API），用于判断凭据能否访问网页路径。
fn probe_path(service: Service) -> &'static str {
    match service {
        Service::Confluence => "/users/viewmyprofile.action",
        _ => "/secure/ViewProfile.jspa",
    }
}

#[derive(Serialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum WebAccess {
    /// Token 即可访问网页路径，无需网页登录。
    Token,
    /// 已有有效的网页会话。
    Session,
    /// 需要网页登录。
    LoginRequired,
}

/// 各系统访问附件、图片等网页路径的方式。
#[tauri::command]
pub async fn web_access_status(state: State<'_, AppState>) -> Result<HashMap<Service, WebAccess>> {
    let mut result = HashMap::new();
    for service in WEB_SERVICES {
        let access = if state.secret(service, Secret::Session)?.is_some() {
            WebAccess::Session
        } else if token_reaches_web(&state, service).await {
            WebAccess::Token
        } else {
            WebAccess::LoginRequired
        };
        result.insert(service, access);
    }
    Ok(result)
}

/// 用 Token 访问一次受保护网页，看是否被重定向到登录页。未配置或网络失败时视为不可访问。
async fn token_reaches_web(state: &AppState, service: Service) -> bool {
    let Ok(ctx) = state.context(service) else { return false };
    let request = ctx.http.get(format!("{}{}", ctx.base_url, probe_path(service))).bearer_auth(ctx.token);
    match request.send().await {
        Ok(response) => response.status().is_success() && !http::is_login_redirect(response.url(), &ctx.base_url),
        Err(_) => false,
    }
}

#[tauri::command]
pub async fn web_logout(state: State<'_, AppState>, service: Service) -> Result<()> {
    state.delete_secret(service, Secret::Session)
}

/// 打开登录窗口。登录完成后窗口自动关闭，并发出 [`SESSION_EVENT`] 事件。
#[tauri::command]
pub async fn web_login(app: AppHandle, state: State<'_, AppState>, service: Service) -> Result<()> {
    let login = login_path(service)?;
    let base = state.config().base_url(service)?.to_string();
    let label = format!("login-{}", service.key());
    if let Some(window) = app.get_webview_window(&label) {
        let _ = window.set_focus();
        return Ok(());
    }
    let url: Url = format!("{base}{login}").parse().map_err(|_| Error::InvalidUrl(base.clone()))?;

    let mut builder = WebviewWindowBuilder::new(&app, &label, WebviewUrl::External(url))
        .title(format!("登录 {}（完成认证后窗口会自动关闭）", service.label()))
        .inner_size(960.0, 760.0);
    let username = state.secret(service, Secret::WebUsername)?;
    let password = state.secret(service, Secret::WebPassword)?;
    if let (Some(username), Some(password)) = (username, password) {
        builder = builder.initialization_script(autofill_script(&base, &username, &password));
    }

    let handle = app.clone();
    builder
        .on_page_load(move |window, payload| {
            if payload.event() != PageLoadEvent::Finished || http::is_login_redirect(payload.url(), &base) {
                return;
            }
            let (handle, base) = (handle.clone(), base.clone());
            // 读取 Cookie 不能在页面加载回调里同步进行
            tauri::async_runtime::spawn(async move {
                if capture_session(&handle, &window, service, &base).await.unwrap_or(false) {
                    let _ = handle.emit(SESSION_EVENT, service);
                    let _ = window.close();
                }
            });
        })
        .build()
        .map_err(|e| Error::Other(format!("无法打开登录窗口：{e}")))?;
    Ok(())
}

/// 登录页的自动填写脚本：填入账号密码、勾选“记住我”后提交。
///
/// 只在本系统的页面上生效；每个登录窗口只自动提交一次，密码错误时停在登录页由用户处理，
/// 避免反复提交导致账号被锁。
fn autofill_script(base: &str, username: &str, password: &str) -> String {
    let origin = Url::parse(base).map(|u| u.origin().ascii_serialization()).unwrap_or_default();
    let quote = |s: &str| serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into());
    format!(
        r#"(function () {{
  if (window.location.origin !== {origin}) return;
  function fill() {{
    var user = document.querySelector('input[name="os_username"]');
    var pass = document.querySelector('input[name="os_password"]');
    if (!user || !pass) return;
    var set = function (input, value) {{
      input.value = value;
      input.dispatchEvent(new Event('input', {{ bubbles: true }}));
      input.dispatchEvent(new Event('change', {{ bubbles: true }}));
    }};
    set(user, {username});
    set(pass, {password});
    var remember = document.querySelector('input[name="os_cookie"]');
    if (remember) remember.checked = true;
    var key = 'nextworkzone-autofill-submitted';
    if (window.sessionStorage.getItem(key)) return;
    window.sessionStorage.setItem(key, '1');
    var form = pass.form;
    var submit = form && form.querySelector('[type="submit"]');
    if (submit) submit.click(); else if (form) form.submit();
  }}
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', fill);
  else fill();
}})();"#,
        origin = quote(&origin),
        username = quote(username),
        password = quote(password),
    )
}

/// 取出登录窗口中的 Cookie，并确认它确实能访问受保护的页面。
async fn capture_session(app: &AppHandle, window: &WebviewWindow, service: Service, base: &str) -> Result<bool> {
    let base_url: Url = base.parse().map_err(|_| Error::InvalidUrl(base.to_string()))?;
    let cookies = window.cookies_for_url(base_url).map_err(|e| Error::Other(e.to_string()))?;
    if cookies.is_empty() {
        return Ok(false);
    }
    let header = cookies.iter().map(|c| format!("{}={}", c.name(), c.value())).collect::<Vec<_>>().join("; ");

    let state = app.state::<AppState>();
    match probe(&state, service, &header).await? {
        Some(updated) => {
            state.set_secret(service, Secret::Session, &updated)?;
            Ok(true)
        }
        None => Ok(false),
    }
}

/// 用会话访问受保护页面。有效时返回（合并了新 Cookie 的）会话，失效时返回 `None`。
async fn probe(state: &AppState, service: Service, cookie: &str) -> Result<Option<String>> {
    let base = state.config().base_url(service)?.to_string();
    let response = state
        .http()
        .get(format!("{base}{}", probe_path(service)))
        .header(reqwest::header::COOKIE, cookie)
        .send()
        .await?;
    if !response.status().is_success() || http::is_login_redirect(response.url(), &base) {
        return Ok(None);
    }
    Ok(Some(http::merge_set_cookies(cookie, &response).unwrap_or_else(|| cookie.to_string())))
}

/// 后台会话保活：定期访问一次受保护页面，让服务端会话保持活跃，并跟上轮换的 Cookie。
/// 会话已失效时清除它并通知前端；网络错误则等下一轮再试。
pub async fn keep_alive_loop(app: AppHandle) {
    let mut interval = tokio::time::interval(KEEP_ALIVE_INTERVAL);
    interval.tick().await; // 第一次立即返回，跳过
    loop {
        interval.tick().await;
        let state = app.state::<AppState>();
        for service in WEB_SERVICES {
            let Ok(Some(cookie)) = state.secret(service, Secret::Session) else { continue };
            match probe(&state, service, &cookie).await {
                Ok(Some(updated)) if updated != cookie => {
                    let _ = state.set_secret(service, Secret::Session, &updated);
                }
                Ok(Some(_)) | Err(_) => {}
                Ok(None) => {
                    let _ = state.delete_secret(service, Secret::Session);
                    let _ = app.emit(SESSION_EVENT, service);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::autofill_script;

    #[test]
    fn autofill_script_escapes_credentials() {
        let script = autofill_script("https://jira.example.com", "zhang\"san", "p'a\"ss</script>\\n");
        assert!(script.contains(r#"window.location.origin !== "https://jira.example.com""#));
        assert!(script.contains(r#"set(user, "zhang\"san");"#));
        assert!(script.contains(r#"set(pass, "p'a\"ss</script>\\n");"#));
    }
}
