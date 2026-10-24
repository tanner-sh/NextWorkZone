//! 网页登录：附件、图片等网页路径不走 REST API，部分部署（例如启用了 2FA / SSO 插件）不接受 Token。
//! 这种情况下在应用内打开登录窗口，用户照常完成认证后，取出会话 Cookie 供下载附件、图片使用。
//!
//! - 先用 Token 探测网页路径；能访问的部署不需要网页登录。
//! - 配置了网页登录账号时，登录窗口会自动填写账号密码并提交，用户只需完成额外的验证步骤。
//! - 后台定期用会话访问一次受保护页面（[`keep_alive_loop`]），让会话保持活跃。

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use nextworkzone_core::secrets::Secret;
use nextworkzone_core::{Error, Result, Service, http};
use serde::Serialize;

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
pub async fn web_access_status(state: &AppState) -> Result<HashMap<Service, WebAccess>> {
    let mut result = HashMap::new();
    for service in WEB_SERVICES {
        let access = if state.secret(service, Secret::Session)?.is_some() {
            WebAccess::Session
        } else if token_reaches_web(state, service).await {
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

pub async fn web_logout(state: &AppState, service: Service) -> Result<()> {
    state.delete_secret(service, Secret::Session)
}

/// 打开登录窗口所需的信息：登录页地址，以及配置了网页登录账号时的自动填写脚本。
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WebLoginInfo {
    pub url: String,
    /// 系统的地址，登录窗口离开登录页后到这个地址下取 Cookie。
    pub base_url: String,
    pub title: String,
    /// 在每个页面开始加载时注入的脚本。
    pub autofill: Option<String>,
}

pub async fn web_login_info(state: &AppState, service: Service) -> Result<WebLoginInfo> {
    let login = login_path(service)?;
    let base = state.config().base_url(service)?.to_string();
    let username = state.secret(service, Secret::WebUsername)?;
    let password = state.secret(service, Secret::WebPassword)?;
    let autofill = match (username, password) {
        (Some(username), Some(password)) => Some(autofill_script(&base, &username, &password)),
        _ => None,
    };
    Ok(WebLoginInfo { url: format!("{base}{login}"), title: format!("登录 {}（完成认证后窗口会自动关闭）", service.label()), base_url: base, autofill })
}

/// 登录窗口中的页面加载完成（`url` 为当前地址）：还停在登录页时返回 false；
/// 否则用窗口中的 Cookie（`cookie` 为 `name=value; ...`）访问受保护页面，有效时保存会话并发出 [`SESSION_EVENT`]，返回 true（可以关闭窗口）。
pub async fn web_login_finish(state: &AppState, service: Service, url: String, cookie: String) -> Result<bool> {
    let base = state.config().base_url(service)?.to_string();
    let Ok(current) = url::Url::parse(&url) else { return Ok(false) };
    if http::is_login_redirect(&current, &base) || cookie.is_empty() {
        return Ok(false);
    }
    match probe(state, service, &cookie).await? {
        Some(updated) => {
            state.set_secret(service, Secret::Session, &updated)?;
            state.emit(SESSION_EVENT, service);
            Ok(true)
        }
        None => Ok(false),
    }
}

/// 登录页的自动填写脚本：填入账号密码、勾选“记住我”后提交。
///
/// 只在本系统的页面上生效；每个登录窗口只自动提交一次，密码错误时停在登录页由用户处理，
/// 避免反复提交导致账号被锁。
fn autofill_script(base: &str, username: &str, password: &str) -> String {
    let origin = url::Url::parse(base).map(|u| u.origin().ascii_serialization()).unwrap_or_default();
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
pub async fn keep_alive_loop(state: Arc<AppState>) {
    let mut interval = tokio::time::interval(KEEP_ALIVE_INTERVAL);
    interval.tick().await; // 第一次立即返回，跳过
    loop {
        interval.tick().await;
        for service in WEB_SERVICES {
            let Ok(Some(cookie)) = state.secret(service, Secret::Session) else { continue };
            match probe(&state, service, &cookie).await {
                Ok(Some(updated)) if updated != cookie => {
                    let _ = state.set_secret(service, Secret::Session, &updated);
                }
                Ok(Some(_)) | Err(_) => {}
                Ok(None) => {
                    let _ = state.delete_secret(service, Secret::Session);
                    state.emit(SESSION_EVENT, service);
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
