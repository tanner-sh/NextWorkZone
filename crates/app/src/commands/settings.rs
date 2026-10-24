use std::collections::HashMap;

use nextworkzone_core::config::{normalize_base_url, parse_page_id};
use nextworkzone_core::secrets::{self, Secret};
use nextworkzone_core::{ConnectionInfo, Error, Result, Service};
use serde::{Deserialize, Serialize};

use crate::commands::session::WEB_SERVICES;
use crate::state::AppState;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServiceSettings {
    service: Service,
    label: &'static str,
    base_url: String,
    has_token: bool,
    /// 是否支持网页登录（用于访问附件、图片等网页路径）。
    supports_web_login: bool,
    /// 网页登录账号，用于登录窗口自动填写。
    web_username: String,
    has_web_password: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    proxy: String,
    services: Vec<ServiceSettings>,
    weekly_page_id: String,
    weekly_person_name: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsInput {
    proxy: String,
    base_urls: HashMap<Service, String>,
    /// 只包含用户本次新填写的 Token；未出现的服务保持原值。
    tokens: HashMap<Service, String>,
    /// 页面地址或页面 ID。
    weekly_page: String,
    weekly_person_name: String,
    /// 只包含支持网页登录的系统。
    web_accounts: HashMap<Service, WebAccountInput>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebAccountInput {
    username: String,
    /// 为空表示不修改。
    password: String,
}

fn settings(state: &AppState) -> Result<Settings> {
    let config = state.config();
    let services = Service::ALL
        .into_iter()
        .map(|service| {
            Ok(ServiceSettings {
                service,
                label: service.label(),
                base_url: config.endpoint(service).base_url.clone(),
                has_token: state.secret(service, Secret::Token)?.is_some(),
                supports_web_login: WEB_SERVICES.contains(&service),
                web_username: state.secret(service, Secret::WebUsername)?.unwrap_or_default(),
                has_web_password: state.secret(service, Secret::WebPassword)?.is_some(),
            })
        })
        .collect::<Result<_>>()?;
    Ok(Settings {
        proxy: config.proxy.unwrap_or_default(),
        services,
        weekly_page_id: config.weekly.page_id,
        weekly_person_name: config.weekly.person_name,
    })
}

pub async fn get_settings(state: &AppState) -> Result<Settings> {
    settings(state)
}

pub async fn save_settings(state: &AppState, input: SettingsInput) -> Result<Settings> {
    let mut config = state.config();
    let proxy = input.proxy.trim();
    config.proxy = (!proxy.is_empty()).then(|| proxy.to_string());
    for (service, url) in &input.base_urls {
        config.endpoint_mut(*service).base_url = normalize_base_url(url)?;
    }
    let weekly_page = input.weekly_page.trim();
    config.weekly.page_id = if weekly_page.is_empty() {
        String::new()
    } else {
        parse_page_id(weekly_page).ok_or_else(|| Error::InvalidUrl(weekly_page.to_string()))?
    };
    config.weekly.person_name = input.weekly_person_name.trim().to_string();
    state.update_config(config)?;

    for (service, token) in &input.tokens {
        let token = token.trim();
        if !token.is_empty() {
            state.set_secret(*service, Secret::Token, token)?;
        }
    }

    // 账号清空时一并删除密码，即关闭自动填写
    for (service, account) in &input.web_accounts {
        if !WEB_SERVICES.contains(service) {
            continue;
        }
        let username = account.username.trim();
        if username.is_empty() {
            state.delete_secret(*service, Secret::WebUsername)?;
            state.delete_secret(*service, Secret::WebPassword)?;
            continue;
        }
        state.set_secret(*service, Secret::WebUsername, username)?;
        if !account.password.is_empty() {
            state.set_secret(*service, Secret::WebPassword, &account.password)?;
        }
    }
    settings(state)
}

pub async fn clear_token(state: &AppState, service: Service) -> Result<Settings> {
    state.delete_secret(service, Secret::Token)?;
    settings(state)
}

/// 开发阶段的便捷入口：把 `~/.nextworkzone/tokens.env` 中的 Token 导入钥匙串，返回导入了哪些服务。
pub async fn import_tokens_env(state: &AppState) -> Result<Vec<Service>> {
    let home = &state.paths.home_dir;
    let content = std::fs::read_to_string(home.join(".nextworkzone/tokens.env"))?;
    let tokens = secrets::parse_tokens_env(&content);
    for (service, token) in &tokens {
        state.set_secret(*service, Secret::Token, token)?;
    }
    Ok(tokens.into_iter().map(|(service, _)| service).collect())
}

pub async fn test_connection(
    state: &AppState,
    service: Service,
) -> Result<ConnectionInfo> {
    match service {
        Service::Jira => state.jira()?.connection_info().await,
        Service::Confluence => state.confluence()?.connection_info().await,
        Service::Gitlab => state.gitlab()?.connection_info().await,
    }
}
