use std::time::Duration;

use reqwest::{Client, RequestBuilder, Response, StatusCode};

use crate::{Error, Result};

/// 构建所有适配器共用的 HTTP 客户端。
/// `proxy` 为空时沿用 reqwest 的默认行为：读取环境变量与系统代理设置。
pub fn build_client(proxy: Option<&str>) -> Result<Client> {
    let mut builder = Client::builder()
        .user_agent(concat!("NextWorkZone/", env!("CARGO_PKG_VERSION")))
        .connect_timeout(Duration::from_secs(10))
        .timeout(Duration::from_secs(60))
        // 代理会关闭较久未用的连接，复用这类连接会报“peer closed connection”，因此缩短空闲保留时间
        .pool_idle_timeout(Duration::from_secs(15))
        .retry(retry_policy());
    if let Some(proxy) = proxy.map(str::trim).filter(|p| !p.is_empty()) {
        let proxy = reqwest::Proxy::all(proxy).map_err(|_| Error::InvalidUrl(proxy.to_string()))?;
        builder = builder.proxy(proxy);
    }
    Ok(builder.build()?)
}

/// 经代理访问内网时偶尔会出现连接被重置等瞬时故障：只读请求（GET）遇到连接级错误时自动重试，
/// 写操作不重试，避免重复提交。
fn retry_policy() -> reqwest::retry::Builder {
    reqwest::retry::for_host(AnyHost)
        .max_retries_per_request(2)
        .classify_fn(|req_rep| {
            if req_rep.method() == reqwest::Method::GET && req_rep.error().is_some() {
                req_rep.retryable()
            } else {
                req_rep.success()
            }
        })
}

/// 重试策略按主机生效；工作台访问的都是用户配置的系统，因此对所有主机生效。
struct AnyHost;

impl PartialEq<&str> for AnyHost {
    fn eq(&self, _host: &&str) -> bool {
        true
    }
}

/// 把非 2xx 响应转换为 [`Error`]，2xx 原样返回。
pub async fn check(response: Response) -> Result<Response> {
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    if status == StatusCode::UNAUTHORIZED {
        return Err(Error::Unauthorized { status: status.as_u16() });
    }
    let body = error_text(&response.text().await.unwrap_or_default());
    if status == StatusCode::FORBIDDEN {
        return Err(Error::Forbidden { body });
    }
    Err(Error::Http { status: status.as_u16(), body })
}

/// 从三个系统的错误响应中提取可读信息：
/// Jira `{"errorMessages": [...], "errors": {字段: 信息}}`，Confluence / GitLab `{"message": ...}`。
fn error_text(body: &str) -> String {
    let Ok(json) = serde_json::from_str::<serde_json::Value>(body) else {
        return truncate(body.trim(), 300);
    };
    let mut messages: Vec<String> = Vec::new();
    for item in json["errorMessages"].as_array().into_iter().flatten() {
        messages.extend(item.as_str().map(str::to_string));
    }
    for (field, message) in json["errors"].as_object().into_iter().flatten() {
        messages.push(format!("{field}：{}", message.as_str().unwrap_or_default()));
    }
    for key in ["message", "error"] {
        match &json[key] {
            serde_json::Value::String(s) => messages.push(s.clone()),
            serde_json::Value::Null => {}
            other => messages.push(other.to_string()),
        }
    }
    if messages.is_empty() { truncate(body.trim(), 300) } else { messages.join("；") }
}

/// 发送请求并返回响应体与 Content-Type，用于附件、图片等二进制内容。
pub async fn fetch_bytes(request: RequestBuilder) -> Result<(Vec<u8>, Option<String>)> {
    let response = check(request.send().await?).await?;
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .map(str::to_string);
    Ok((response.bytes().await?.to_vec(), content_type))
}

/// 登录页、单点登录页路径中的常见片段。
const LOGIN_PATH_MARKERS: &[&str] = &["login", "signin", "sign_in", "/sso", "/saml", "/cas/", "/oauth"];

/// 网页路径不接受当前凭据时（例如被 2FA / SSO 拦截），请求会被重定向到登录页：
/// 要么跳到了其他主机（统一认证服务），要么跳到了本系统的登录页。
pub fn is_login_redirect(url: &reqwest::Url, base: &str) -> bool {
    let other_host = reqwest::Url::parse(base).is_ok_and(|b| b.host_str() != url.host_str());
    let path = url.path().to_ascii_lowercase();
    other_host || LOGIN_PATH_MARKERS.iter().any(|m| path.contains(m))
}

/// 把响应中的 `Set-Cookie` 合并进已有的 `Cookie` 请求头（同名覆盖、新增追加），
/// 用于跟上服务端轮换的会话 Cookie。没有变化时返回 `None`。
pub fn merge_set_cookies(header: &str, response: &Response) -> Option<String> {
    let mut cookies: Vec<(String, String)> = header
        .split(';')
        .filter_map(|pair| pair.trim().split_once('='))
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect();
    let mut changed = false;
    for value in response.headers().get_all(reqwest::header::SET_COOKIE) {
        let Some((name, value)) = value.to_str().ok().and_then(|v| v.split(';').next()).and_then(|p| p.trim().split_once('=')) else {
            continue;
        };
        match cookies.iter_mut().find(|(k, _)| k == name) {
            Some((_, old)) if old == value => {}
            Some((_, old)) => {
                *old = value.to_string();
                changed = true;
            }
            None => {
                cookies.push((name.to_string(), value.to_string()));
                changed = true;
            }
        }
    }
    changed.then(|| cookies.iter().map(|(k, v)| format!("{k}={v}")).collect::<Vec<_>>().join("; "))
}

fn truncate(text: &str, max_chars: usize) -> String {
    match text.char_indices().nth(max_chars) {
        Some((idx, _)) => format!("{}…", &text[..idx]),
        None => text.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::{is_login_redirect, merge_set_cookies};

    #[test]
    fn detects_login_redirects() {
        let base = "https://jira.example.com";
        let url = |s: &str| reqwest::Url::parse(s).unwrap();
        assert!(is_login_redirect(&url("https://jira.example.com/login.jsp?x=1"), base));
        assert!(is_login_redirect(&url("https://jira.example.com/plugins/servlet/mfa/authlogin"), base));
        assert!(is_login_redirect(&url("https://sso.example.com/idp/start"), base));
        assert!(!is_login_redirect(&url("https://jira.example.com/secure/attachment/1/a.png"), base));
    }

    fn response(set_cookies: &[&str]) -> reqwest::Response {
        let mut builder = http::Response::builder();
        for c in set_cookies {
            builder = builder.header("set-cookie", *c);
        }
        reqwest::Response::from(builder.body(Vec::<u8>::new()).unwrap())
    }

    #[test]
    fn merges_rotated_cookies() {
        let header = "JSESSIONID=old; token=a";
        let merged = merge_set_cookies(header, &response(&["JSESSIONID=new; Path=/; HttpOnly", "extra=1; Path=/"]));
        assert_eq!(merged.as_deref(), Some("JSESSIONID=new; token=a; extra=1"));
        assert_eq!(merge_set_cookies(header, &response(&["token=a; Path=/"])), None);
        assert_eq!(merge_set_cookies(header, &response(&[])), None);
    }
}
