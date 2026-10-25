//! macOS 原生界面使用的接口。命令与 Tauri 前端相同，都经过 [`nextworkzone_app::dispatch`]：
//! 按名称调用，参数和结果都是 JSON 文本。另外提供图片读取和剪贴板面板需要的几个函数。
//!
//! 所有异步调用都在这里自己的 tokio 运行时中执行，Swift 端只是等待结果。

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock};

use nextworkzone_app::{AppState, Host, Paths, Shortcut};
use nextworkzone_core::secrets::Store;
use serde_json::Value;

uniffi::setup_scaffolding!();

static RUNTIME: LazyLock<tokio::runtime::Runtime> =
    LazyLock::new(|| tokio::runtime::Builder::new_multi_thread().enable_all().thread_name("nextworkzone").build().expect("无法创建异步运行时"));

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    /// 可以直接显示给用户的错误信息。
    #[error("{message}")]
    Failed { message: String },
}

impl From<nextworkzone_core::Error> for CoreError {
    fn from(e: nextworkzone_core::Error) -> Self {
        CoreError::Failed { message: e.to_string() }
    }
}

fn failed(message: impl ToString) -> CoreError {
    CoreError::Failed { message: message.to_string() }
}

/// Swift 端实现的平台能力（见 [`Host`]）。快捷键名称为 `capture` / `clipboard`。
#[uniffi::export(with_foreign)]
pub trait NativeHost: Send + Sync {
    /// 事件载荷为 JSON 文本。
    fn emit(&self, event: String, payload: String);
    /// 未移植的设置变更由 Swift 保存，失败时不更新 Rust 内存。
    fn persist_config(&self, json: String) -> Option<String>;
    fn notify(&self, title: String, body: String);
    /// 打开失败时返回原因。
    fn open_path(&self, path: String) -> Option<String>;
    /// 注册失败时返回原因。
    fn set_shortcut(&self, action: String, shortcut: String) -> Option<String>;
    fn shortcut_error(&self, action: String) -> Option<String>;
    fn hide_clipboard_panel(&self, restore: bool);
    fn clipboard_paused(&self, paused: bool);
}

fn shortcut_name(action: Shortcut) -> String {
    match action {
        Shortcut::Capture => "capture".into(),
        Shortcut::Clipboard => "clipboard".into(),
    }
}

struct HostAdapter(Arc<dyn NativeHost>);

impl Host for HostAdapter {
    fn persist_config(&self, config: &nextworkzone_core::AppConfig) -> nextworkzone_core::Result<()> {
        match self.0.persist_config(serde_json::to_string(config)?) {
            Some(message) => Err(nextworkzone_core::Error::Other(message)),
            None => Ok(()),
        }
    }

    fn emit(&self, event: &str, payload: Value) {
        self.0.emit(event.to_string(), payload.to_string());
    }

    fn notify(&self, title: &str, body: &str) {
        self.0.notify(title.to_string(), body.to_string());
    }

    fn open_path(&self, path: &Path) -> nextworkzone_core::Result<()> {
        match self.0.open_path(path.to_string_lossy().into_owned()) {
            Some(e) => Err(nextworkzone_core::Error::Other(e)),
            None => Ok(()),
        }
    }

    fn set_shortcut(&self, action: Shortcut, shortcut: &str) -> nextworkzone_core::Result<()> {
        match self.0.set_shortcut(shortcut_name(action), shortcut.to_string()) {
            Some(e) => Err(nextworkzone_core::Error::Other(e)),
            None => Ok(()),
        }
    }

    fn shortcut_error(&self, action: Shortcut) -> Option<String> {
        self.0.shortcut_error(shortcut_name(action))
    }

    fn hide_clipboard_panel(&self, restore: bool) {
        self.0.hide_clipboard_panel(restore);
    }

    fn clipboard_paused(&self, paused: bool) {
        self.0.clipboard_paused(paused);
    }
}

/// 配置目录属于 Swift，数据目录暂时只供尚未移植的业务库使用。
#[derive(uniffi::Record)]
pub struct CorePaths {
    pub config_dir: String,
    pub data_dir: String,
    pub cache_dir: String,
    pub home_dir: String,
    pub download_dir: String,
}

#[derive(uniffi::Record)]
pub struct Asset {
    pub data: Vec<u8>,
    pub content_type: Option<String>,
}

/// 拖到其他应用的文件和预览图（PNG）。
#[derive(uniffi::Record)]
pub struct DragFiles {
    pub paths: Vec<String>,
    pub preview: Vec<u8>,
}

/// 打开剪贴板面板前位于前台的应用。
#[derive(uniffi::Record)]
pub struct ClipTarget {
    pub name: String,
    pub pid: Option<u32>,
    /// 是否就是本应用。
    pub is_self: bool,
}

#[derive(uniffi::Object)]
pub struct Core {
    state: Arc<AppState>,
    background_started: AtomicBool,
}

#[uniffi::export]
impl Core {
    /// 载入配置和本机数据，并启动后台同步、剪贴板记录。
    #[uniffi::constructor]
    pub fn new(paths: CorePaths, host: Arc<dyn NativeHost>) -> Result<Arc<Self>, CoreError> {
        let store = Store::memory();
        let paths = Paths {
            config_dir: paths.config_dir.into(),
            data_dir: paths.data_dir.into(),
            cache_dir: paths.cache_dir.into(),
            home_dir: paths.home_dir.into(),
            download_dir: paths.download_dir.into(),
        };
        let _guard = RUNTIME.enter();
        let state = Arc::new(AppState::load(paths, store, Arc::new(HostAdapter(host)))?);
        Ok(Arc::new(Self { state, background_started: AtomicBool::new(false) }))
    }

    /// 配置已由 Swift 落盘，这里只更新内存及代理客户端。
    pub fn bridge_set_config(&self, json: String) -> Result<(), CoreError> {
        self.state.bridge_set_config(serde_json::from_str(&json).map_err(failed)?)?;
        Ok(())
    }

    /// 启动时先收齐新配置与凭据，再启动后台任务，避免读取旧设置或抢跑请求。
    pub fn bridge_set_secrets(&self, json: String) -> Result<(), CoreError> {
        self.state.bridge_set_secrets(serde_json::from_str(&json).map_err(failed)?)?;
        if !self.background_started.swap(true, Ordering::SeqCst) {
            let _guard = RUNTIME.enter();
            nextworkzone_app::start_background(&self.state).map_err(failed)?;
        }
        Ok(())
    }

    /// 调用命令：`args` 为 JSON 对象（参数名为 camelCase），返回 JSON 文本。
    pub async fn call(&self, cmd: String, args: String) -> Result<String, CoreError> {
        let state = self.state.clone();
        RUNTIME
            .spawn(async move {
                let args: Value = if args.trim().is_empty() { Value::Object(Default::default()) } else { serde_json::from_str(&args).map_err(failed)? };
                let value = nextworkzone_app::dispatch(&state, &cmd, args).await?;
                Ok(value.to_string())
            })
            .await
            .map_err(failed)?
    }

    /// 读取图片等资源，路径格式见 [`nextworkzone_app::asset`]。
    pub async fn asset(&self, path: String) -> Result<Asset, CoreError> {
        let state = self.state.clone();
        RUNTIME
            .spawn(async move {
                let (data, content_type) = nextworkzone_app::asset::fetch(&state, &path).await?;
                Ok(Asset { data, content_type })
            })
            .await
            .map_err(failed)?
    }

    /// 打开剪贴板面板前调用：记下位于前台的应用，返回它的名称（本应用时为空）。
    pub fn clip_capture_target(&self) -> Option<String> {
        self.state.clip.capture_target()
    }

    /// 打开面板前位于前台的应用。
    pub fn clip_target(&self) -> Option<ClipTarget> {
        self.state.clip.target().map(|t| ClipTarget { is_self: t.pid == Some(std::process::id()), name: t.name, pid: t.pid })
    }

    /// 暂停或恢复记录（托盘菜单）。
    pub fn clip_toggle_paused(&self) {
        nextworkzone_app::clipboard::toggle_paused(&self.state);
    }

    pub fn clip_paused(&self) -> bool {
        self.state.clip.paused().is_some()
    }

    /// 把图片、文件条目准备为可以拖到其他应用的文件。
    pub fn clip_drag_files(&self, ids: Vec<String>, fallback_icon: Vec<u8>) -> Result<DragFiles, CoreError> {
        let files = nextworkzone_app::clipboard::drag_files(&self.state.clip, &ids, &fallback_icon)?;
        Ok(DragFiles { paths: files.paths.iter().map(|p| p.to_string_lossy().into_owned()).collect(), preview: files.preview })
    }

    /// 拖到其他应用后标记为刚刚使用。
    pub fn clip_touch(&self, ids: Vec<String>) {
        let _ = self.state.clip.store.touch(&ids);
    }

    /// 当前配置中的快捷键：`capture` / `clipboard`（关闭时为空）。
    pub fn configured_shortcut(&self, action: String) -> String {
        let config = self.state.config();
        match action.as_str() {
            "capture" => config.workspace.capture_shortcut,
            "clipboard" if config.tools.clipboard.enabled => config.tools.clipboard.shortcut,
            _ => String::new(),
        }
    }

    /// 剪贴板工具是否开启。
    pub fn clipboard_enabled(&self) -> bool {
        self.state.config().tools.clipboard.enabled
    }
}
