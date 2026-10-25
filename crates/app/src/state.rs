use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};
use std::sync::atomic::{AtomicBool, Ordering};

use nextworkzone_confluence::ConfluenceClient;
use nextworkzone_confluence::index::WikiIndex;
use nextworkzone_core::cache::Cache;
use nextworkzone_core::secrets::{self, Secret, Store};
use nextworkzone_core::{AppConfig, Error, Result, Service, http};
use nextworkzone_gitlab::GitlabClient;
use nextworkzone_jira::JiraClient;
use nextworkzone_jira::index::IssueIndex;
use nextworkzone_workspace::Workspace;
use serde::Serialize;

use crate::clipboard::Clip;
use crate::host::Host;

/// 应用使用的本机目录。
#[derive(Clone, Debug)]
pub struct Paths {
    /// 配置文件 `config.json` 所在目录。
    pub config_dir: PathBuf,
    /// 数据库等长期数据。
    pub data_dir: PathBuf,
    /// 可随时删除的缓存。
    pub cache_dir: PathBuf,
    pub home_dir: PathBuf,
    /// 打开附件时保存到这里。
    pub download_dir: PathBuf,
}

/// 应用运行期状态：配置、按代理设置构建好的 HTTP 客户端，以及凭据的内存缓存。
/// 凭据在首次使用时一次性读出，之后不再访问钥匙串。
pub struct AppState {
    pub paths: Paths,
    config_path: PathBuf,
    /// 窗口、通知、快捷键等平台能力。
    pub host: Arc<dyn Host>,
    /// 剪贴板历史与后台记录。
    pub clip: Clip,
    pub cache: Cache,
    /// 待办、笔记、知识库的本地数据。
    pub workspace: Arc<Workspace>,
    /// 本机问题库与问题的查看记录。
    pub issue_index: Arc<IssueIndex>,
    /// 本机 Wiki 库与页面的查看记录。
    pub wiki_index: Arc<WikiIndex>,
    store: Store,
    bridge_initialized: AtomicBool,
    inner: RwLock<Inner>,
    /// 当前 Jira 用户名，按“地址 + 令牌”缓存，切换账号后自动失效。
    jira_user: RwLock<Option<(String, String)>>,
    /// 当前 Wiki 用户的 (userkey, 用户名)，按“地址 + 令牌”缓存。
    wiki_user: RwLock<Option<(String, (String, String))>>,
}

struct Inner {
    config: AppConfig,
    http: reqwest::Client,
    /// 尚未读取时为 `None`。
    secrets: Option<HashMap<String, String>>,
}

/// 调用某个系统所需的全部信息，取出后即可脱离锁使用。
pub struct ServiceContext {
    pub http: reqwest::Client,
    pub base_url: String,
    pub token: String,
}

impl AppState {
    pub fn load(paths: Paths, store: Store, host: Arc<dyn Host>) -> Result<Self> {
        let config_path = paths.config_dir.join("config.json");
        let config = if store.is_memory() { AppConfig::default() } else { AppConfig::load(&config_path)? };
        let http = http::build_client(config.proxy.as_deref())?;
        let data_dir = paths.data_dir.clone();
        Ok(Self {
            clip: Clip::open(&data_dir.join("clipboard"))?,
            cache: Cache::new(paths.cache_dir.clone()),
            paths,
            config_path,
            host,
            workspace: Arc::new(Workspace::open(&data_dir.join("workspace.db"))?),
            issue_index: Arc::new(IssueIndex::open(&data_dir.join("jira-index.db"))?),
            wiki_index: Arc::new(WikiIndex::open(&data_dir.join("wiki-index.db"))?),
            store,
            bridge_initialized: AtomicBool::new(false),
            inner: RwLock::new(Inner { config, http, secrets: None }),
            jira_user: RwLock::new(None),
            wiki_user: RwLock::new(None),
        })
    }

    /// 把事件发给界面；载荷无法序列化时发送 `null`。
    pub fn emit(&self, event: &str, payload: impl Serialize) {
        self.host.emit(event, serde_json::to_value(payload).unwrap_or_default());
    }

    pub fn config(&self) -> AppConfig {
        self.inner.read().unwrap().config.clone()
    }

    pub fn http(&self) -> reqwest::Client {
        self.inner.read().unwrap().http.clone()
    }

    /// 保存配置；原生宿主统一落盘，尚未移植的设置也不会写回旧目录。
    pub fn update_config(&self, config: AppConfig) -> Result<()> {
        self.replace_config(config, true)
    }

    /// Swift 已经保存的配置仅推入内存，避免循环写回宿主。
    pub fn bridge_set_config(&self, config: AppConfig) -> Result<()> {
        let previous = self.config();
        self.replace_config(config.clone(), false)?;
        self.update_secrets(|values| {
            for service in Service::ALL {
                if self.bridge_initialized.load(Ordering::SeqCst) && previous.endpoint(service).base_url != config.endpoint(service).base_url {
                    values.remove(&secrets::key(service, Secret::Session));
                }
            }
        })
    }

    fn replace_config(&self, config: AppConfig, persist: bool) -> Result<()> {
        let client = if self.config().proxy != config.proxy { Some(http::build_client(config.proxy.as_deref())?) } else { None };
        if persist {
            if self.store.is_memory() { self.host.persist_config(&config)?; }
            else { config.save(&self.config_path)?; }
        }
        let mut inner = self.inner.write().unwrap();
        if let Some(client) = client { inner.http = client; }
        inner.config = config;
        Ok(())
    }

    /// 令牌和网页登录账号由 Swift 管理；会话仍由 Rust 保留，换账号时使其失效。
    pub fn bridge_set_secrets(&self, next: HashMap<String, String>) -> Result<()> {
        let initialized = self.bridge_initialized.load(Ordering::SeqCst);
        self.update_secrets(|values| {
            for service in Service::ALL {
                let changed = [Secret::Token, Secret::WebUsername, Secret::WebPassword].into_iter()
                    .any(|kind| {
                        let key = secrets::key(service, kind);
                        values.get(&key) != next.get(&key)
                    });
                if initialized && changed { values.remove(&secrets::key(service, Secret::Session)); }
            }
            values.retain(|key, _| key.ends_with("-session"));
            values.extend(next.into_iter().filter(|(key, _)| !key.ends_with("-session")));
        })?;
        self.bridge_initialized.store(true, Ordering::SeqCst);
        Ok(())
    }

    /// 全部凭据；首次调用时从存储中读出。
    fn secrets(&self) -> Result<HashMap<String, String>> {
        if let Some(secrets) = &self.inner.read().unwrap().secrets {
            return Ok(secrets.clone());
        }
        let mut loaded = self.store.load()?;
        if self.store.is_memory() {
            // 这里只读新配置目录里的会话文件，不读取旧版凭据；P6 随会话实现一起移植。
            let sessions = Store::File(self.paths.config_dir.join("web-sessions.json")).load()?;
            loaded.extend(sessions.into_iter().filter(|(key, _)| key.ends_with("-session")));
        }
        let mut inner = self.inner.write().unwrap();
        Ok(inner.secrets.get_or_insert(loaded).clone())
    }

    fn update_secrets(&self, change: impl FnOnce(&mut HashMap<String, String>)) -> Result<()> {
        let mut secrets = self.secrets()?;
        change(&mut secrets);
        self.store.save(&secrets)?;
        if self.store.is_memory() {
            let sessions = secrets.iter().filter(|(key, _)| key.ends_with("-session"))
                .map(|(key, value)| (key.clone(), value.clone())).collect();
            Store::File(self.paths.config_dir.join("web-sessions.json")).save(&sessions)?;
        }
        self.inner.write().unwrap().secrets = Some(secrets);
        Ok(())
    }

    pub fn secret(&self, service: Service, kind: Secret) -> Result<Option<String>> {
        Ok(self.secrets()?.get(&secrets::key(service, kind)).cloned())
    }

    pub fn set_secret(&self, service: Service, kind: Secret, value: &str) -> Result<()> {
        self.update_secrets(|s| {
            s.insert(secrets::key(service, kind), value.to_string());
        })
    }

    pub fn delete_secret(&self, service: Service, kind: Secret) -> Result<()> {
        self.update_secrets(|s| {
            s.remove(&secrets::key(service, kind));
        })
    }

    pub fn context(&self, service: Service) -> Result<ServiceContext> {
        let token = self.secret(service, Secret::Token)?.ok_or(Error::MissingToken(service))?;
        let inner = self.inner.read().unwrap();
        Ok(ServiceContext {
            http: inner.http.clone(),
            base_url: inner.config.base_url(service)?.to_string(),
            token,
        })
    }

    pub fn jira(&self) -> Result<JiraClient> {
        let ctx = self.context(Service::Jira)?;
        Ok(JiraClient::new(ctx.http, ctx.base_url, ctx.token))
    }

    /// 当前 Jira 用户的用户名（首次查询后缓存）。
    pub async fn jira_username(&self) -> Result<String> {
        let ctx = self.context(Service::Jira)?;
        let fingerprint = format!("{}|{}", ctx.base_url, ctx.token);
        if let Some((_, name)) = self.jira_user.read().unwrap().as_ref().filter(|(fp, _)| *fp == fingerprint) {
            return Ok(name.clone());
        }
        let name = JiraClient::new(ctx.http, ctx.base_url, ctx.token).my_username().await?;
        *self.jira_user.write().unwrap() = Some((fingerprint, name.clone()));
        Ok(name)
    }

    pub fn confluence(&self) -> Result<ConfluenceClient> {
        let ctx = self.context(Service::Confluence)?;
        Ok(ConfluenceClient::new(ctx.http, ctx.base_url, ctx.token))
    }

    /// 当前 Wiki 用户的 (userkey, 用户名)（首次查询后缓存）。
    pub async fn wiki_me(&self) -> Result<(String, String)> {
        let ctx = self.context(Service::Confluence)?;
        let fingerprint = format!("{}|{}", ctx.base_url, ctx.token);
        if let Some((_, me)) = self.wiki_user.read().unwrap().as_ref().filter(|(fp, _)| *fp == fingerprint) {
            return Ok(me.clone());
        }
        let me = ConfluenceClient::new(ctx.http, ctx.base_url, ctx.token).me().await?;
        *self.wiki_user.write().unwrap() = Some((fingerprint, me.clone()));
        Ok(me)
    }

    pub fn gitlab(&self) -> Result<GitlabClient> {
        let ctx = self.context(Service::Gitlab)?;
        Ok(GitlabClient::new(ctx.http, ctx.base_url, ctx.token))
    }

    /// 下载系统内的网页资源（附件、图片）。
    ///
    /// 有网页会话时使用会话 Cookie，否则先用 Token 尝试（部分部署的网页路径会被 2FA / SSO 拦截，
    /// 只能使用网页登录得到的会话）；
    /// 会话失效（被重定向到登录页）时清除会话并返回 [`Error::SessionRequired`]。
    /// GitLab 没有这一限制，直接使用 Token。
    pub async fn fetch_web(&self, service: Service, url: &str) -> Result<(Vec<u8>, Option<String>)> {
        let ctx = self.context(service)?;
        if service == Service::Gitlab {
            return http::fetch_bytes(ctx.http.get(url).header("PRIVATE-TOKEN", ctx.token)).await;
        }
        // 没有会话时先用 Token 试一下：很多部署下 Token 就能访问网页路径。
        let cookie = self.secret(service, Secret::Session)?;
        let request = match &cookie {
            Some(cookie) => ctx.http.get(url).header(reqwest::header::COOKIE, cookie),
            None => ctx.http.get(url).bearer_auth(ctx.token),
        };
        let response = request.send().await?;
        if http::is_login_redirect(response.url(), &ctx.base_url) {
            if cookie.is_some() {
                self.delete_secret(service, Secret::Session)?;
            }
            return Err(Error::SessionRequired(service));
        }
        if let Some(updated) = cookie.as_deref().and_then(|c| http::merge_set_cookies(c, &response)) {
            self.set_secret(service, Secret::Session, &updated)?;
        }
        let response = http::check(response).await?;
        let content_type = response
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .map(str::to_string);
        Ok((response.bytes().await?.to_vec(), content_type))
    }

    /// 把相对路径或完整地址解析为本系统的完整地址；不属于本系统的地址会被拒绝，避免凭据外泄。
    pub fn resolve_url(&self, service: Service, path_or_url: &str) -> Result<String> {
        let base = self.config().base_url(service)?.to_string();
        if path_or_url.starts_with('/') && !path_or_url.starts_with("//") {
            Ok(format!("{base}{path_or_url}"))
        } else if path_or_url.starts_with(&format!("{base}/")) {
            Ok(path_or_url.to_string())
        } else {
            Err(Error::InvalidUrl(path_or_url.to_string()))
        }
    }
}

#[cfg(test)]
mod bridge_tests {
    use super::*;
    use crate::host::Shortcut;
    use std::path::Path;
    use std::sync::Mutex;

    #[derive(Default)]
    struct TestHost { saved: Mutex<Option<AppConfig>> }
    impl Host for TestHost {
        fn persist_config(&self, config: &AppConfig) -> Result<()> { *self.saved.lock().unwrap() = Some(config.clone()); Ok(()) }
        fn emit(&self, _: &str, _: serde_json::Value) {}
        fn notify(&self, _: &str, _: &str) {}
        fn open_path(&self, _: &Path) -> Result<()> { Ok(()) }
        fn set_shortcut(&self, _: Shortcut, _: &str) -> Result<()> { Ok(()) }
        fn shortcut_error(&self, _: Shortcut) -> Option<String> { None }
        fn hide_clipboard_panel(&self, _: bool) {}
        fn clipboard_paused(&self, _: bool) {}
    }

    struct Temporary(PathBuf);
    impl Temporary {
        fn new() -> Self {
            let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
            static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
            let serial = NEXT.fetch_add(1, Ordering::Relaxed);
            let dir = std::env::temp_dir().join(format!("nwz-bridge-{}-{stamp}-{serial}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            Self(dir)
        }
        fn state(&self, host: Arc<TestHost>) -> AppState {
            AppState::load(Paths { config_dir: self.0.clone(), data_dir: self.0.join("legacy"), cache_dir: self.0.join("cache"), home_dir: self.0.clone(), download_dir: self.0.clone() }, Store::memory(), host).unwrap()
        }
    }
    impl Drop for Temporary { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }

    #[test]
    fn managed_state_never_loads_old_configuration_or_credentials() {
        let temp = Temporary::new();
        std::fs::write(temp.0.join("config.json"), "invalid legacy config").unwrap();
        std::fs::write(temp.0.join("dev-credentials.json"), "invalid legacy credentials").unwrap();
        let state = temp.state(Arc::new(TestHost::default()));
        assert!(state.config().jira.base_url.is_empty());
        assert_eq!(state.secret(Service::Jira, Secret::Token).unwrap(), None);
        let mut config = AppConfig::default();
        config.jira.base_url = "https://jira.example.com".into();
        state.bridge_set_config(config).unwrap();
        assert_eq!(std::fs::read_to_string(temp.0.join("config.json")).unwrap(), "invalid legacy config");
    }

    #[test]
    fn remaining_settings_are_saved_by_the_swift_host() {
        let temp = Temporary::new();
        let host = Arc::new(TestHost::default());
        let state = temp.state(host.clone());
        let mut config = AppConfig::default();
        config.workspace.sync_dir = "/tmp/shared".into();
        state.update_config(config).unwrap();
        assert_eq!(host.saved.lock().unwrap().as_ref().unwrap().workspace.sync_dir, "/tmp/shared");
        assert!(!temp.0.join("config.json").exists());
    }

    #[test]
    fn sessions_survive_restart_and_clear_when_account_changes() {
        let temp = Temporary::new();
        let mut config = AppConfig::default();
        config.jira.base_url = "https://jira.example.com".into();
        let secrets = HashMap::from([("jira".to_string(), "sample-token".to_string())]);
        {
            let state = temp.state(Arc::new(TestHost::default()));
            state.bridge_set_config(config.clone()).unwrap();
            state.bridge_set_secrets(secrets.clone()).unwrap();
            state.set_secret(Service::Jira, Secret::Session, "session=sample").unwrap();
        }
        let state = temp.state(Arc::new(TestHost::default()));
        state.bridge_set_config(config).unwrap();
        state.bridge_set_secrets(secrets.clone()).unwrap();
        assert_eq!(state.secret(Service::Jira, Secret::Session).unwrap().as_deref(), Some("session=sample"));
        state.bridge_set_secrets(secrets).unwrap();
        assert_eq!(state.secret(Service::Jira, Secret::Session).unwrap().as_deref(), Some("session=sample"));
        let text = std::fs::read_to_string(temp.0.join("web-sessions.json")).unwrap();
        assert!(!text.contains("sample-token"));
        state.bridge_set_secrets(HashMap::new()).unwrap();
        assert_eq!(state.secret(Service::Jira, Secret::Session).unwrap(), None);
    }
}
