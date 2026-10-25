//! 凭据（Token、网页会话 Cookie）的存储。
//!
//! 正式版：全部凭据合并为系统钥匙串中的**一个**条目，启动时读取一次，
//! 这样每次安装新版本后最多只会弹出一次钥匙串授权。
//! 开发版：每次编译后程序签名都会变化，钥匙串的“始终允许”会失效，
//! 因此改为存放在仅当前用户可读（0600）的本地文件中。

use std::collections::HashMap;
use std::path::PathBuf;

use keyring::Entry;

use crate::{Result, Service};

const KEYCHAIN_SERVICE: &str = "com.nextworkzone.desktop";
const KEYCHAIN_ACCOUNT: &str = "credentials";

/// 凭据种类。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Secret {
    /// 个人访问令牌，用于 REST API。
    Token,
    /// 网页登录后的会话 Cookie（`Cookie` 请求头的值），用于 Token 无法访问的网页路径（附件、图片等）。
    Session,
    /// 网页登录的账号与密码，用于在登录窗口中自动填写。
    WebUsername,
    WebPassword,
}

pub fn key(service: Service, kind: Secret) -> String {
    match kind {
        Secret::Token => service.key().to_string(),
        Secret::Session => format!("{}-session", service.key()),
        Secret::WebUsername => format!("{}-username", service.key()),
        Secret::WebPassword => format!("{}-password", service.key()),
    }
}

pub enum Store {
    Keychain,
    File(PathBuf),
    Memory(std::sync::RwLock<HashMap<String, String>>),
}

impl Store {
    pub fn memory() -> Self { Self::Memory(std::sync::RwLock::new(HashMap::new())) }

    pub fn is_memory(&self) -> bool { matches!(self, Self::Memory(_)) }

    pub fn load(&self) -> Result<HashMap<String, String>> {
        let text = match self {
            Store::Memory(values) => return Ok(values.read().unwrap().clone()),
            Store::Keychain => match Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)?.get_password() {
                Ok(text) => text,
                Err(keyring::Error::NoEntry) => return Ok(HashMap::new()),
                Err(e) => return Err(e.into()),
            },
            Store::File(path) => match std::fs::read_to_string(path) {
                Ok(text) => text,
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(HashMap::new()),
                Err(e) => return Err(e.into()),
            },
        };
        Ok(serde_json::from_str(&text)?)
    }

    pub fn save(&self, secrets: &HashMap<String, String>) -> Result<()> {
        let text = serde_json::to_string(secrets)?;
        match self {
            Store::Memory(values) => *values.write().unwrap() = secrets.clone(),
            Store::Keychain => Entry::new(KEYCHAIN_SERVICE, KEYCHAIN_ACCOUNT)?.set_password(&text)?,
            Store::File(path) => write_private(path, &text)?,
        }
        Ok(())
    }
}

/// 写入仅当前用户可读写的文件。
fn write_private(path: &std::path::Path, text: &str) -> std::io::Result<()> {
    use std::io::Write;
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options.open(path)?.write_all(text.as_bytes())
}

/// 解析开发阶段使用的 `tokens.env`（`KEY=VALUE` 每行一个）。
pub fn parse_tokens_env(content: &str) -> Vec<(Service, String)> {
    content
        .lines()
        .filter_map(|line| {
            let (key, value) = line.trim().split_once('=')?;
            let value = value.trim().trim_matches(|c| c == '"' || c == '\'');
            let service = match key.trim() {
                "JIRA_PAT" => Service::Jira,
                "WIKI_PAT" | "CONFLUENCE_PAT" => Service::Confluence,
                "GITLAB_PAT" => Service::Gitlab,
                _ => return None,
            };
            (!value.is_empty()).then(|| (service, value.to_string()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_tokens_env() {
        let parsed = parse_tokens_env("JIRA_PAT=abc\n# comment\nWIKI_PAT=\"def\"\nGITLAB_PAT=\nOTHER=x\n");
        assert_eq!(
            parsed,
            vec![(Service::Jira, "abc".to_string()), (Service::Confluence, "def".to_string())]
        );
    }
}
