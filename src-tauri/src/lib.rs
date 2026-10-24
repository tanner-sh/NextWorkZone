mod asset;
mod capture;
mod clipboard;
mod devbridge;
mod host;
mod session;
mod shortcuts;
mod tray;

use std::sync::Arc;

use nextworkzone_app::{AppState, Paths};
use nextworkzone_core::Result;
use nextworkzone_core::secrets::Store;
use serde_json::Value;
use tauri::{Manager, State};

/// 应用层的全部命令都经过这里（见 [`nextworkzone_app::dispatch`]）；窗口相关的命令单独登记。
#[tauri::command]
async fn core(state: State<'_, Arc<AppState>>, cmd: String, args: Value) -> Result<Value> {
    nextworkzone_app::dispatch(&state, &cmd, args).await
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
        .register_asynchronous_uri_scheme_protocol("nextworkzone", asset::handle)
        .setup(|app| {
            let path = app.path();
            let paths = Paths {
                config_dir: path.app_config_dir()?,
                data_dir: path.app_data_dir()?,
                cache_dir: path.app_cache_dir()?,
                home_dir: path.home_dir()?,
                download_dir: path.download_dir()?,
            };
            // 开发版每次编译签名都会变，钥匙串会反复要求授权，因此改用本地私有文件
            let store = if cfg!(debug_assertions) {
                Store::File(paths.config_dir.join("dev-credentials.json"))
            } else {
                Store::Keychain
            };
            let state = Arc::new(AppState::load(paths, store, Arc::new(host::TauriHost(app.handle().clone())))?);
            app.manage(state.clone());
            tauri::async_runtime::block_on(async { nextworkzone_app::start_background(&state) })?;
            tray::setup(app.handle())?;
            capture::setup(app.handle())?;
            clipboard::setup(app.handle())?;
            // 本机测试通道只在开发构建中启动
            if cfg!(debug_assertions) {
                devbridge::start(app.handle());
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            core,
            session::web_login,
            devbridge::dev_eval_result,
            capture::capture_hide,
            capture::capture_clipboard,
            capture::clipboard_read_text,
            clipboard::clip_hide,
            clipboard::clip_open_main,
            clipboard::clip_drag,
        ])
        // 关闭主窗口只是隐藏，应用继续在后台同步、提醒；从托盘重新打开，托盘菜单“退出”才退出
        .on_window_event(|window, event| match (window.label(), event) {
            ("main", tauri::WindowEvent::CloseRequested { api, .. }) => {
                api.prevent_close();
                let _ = window.hide();
            }
            // 快速记录窗口：关闭只是隐藏；切到别的应用时自动收起
            (capture::CAPTURE_LABEL, tauri::WindowEvent::CloseRequested { api, .. }) => {
                api.prevent_close();
                capture::hide(window.app_handle());
            }
            (capture::CAPTURE_LABEL, tauri::WindowEvent::Focused(false)) => {
                let _ = window.hide();
            }
            // 剪贴板面板：同上，切到别的应用时收起
            (clipboard::PANEL_LABEL, tauri::WindowEvent::CloseRequested { api, .. }) => {
                api.prevent_close();
                clipboard::hide(window.app_handle(), false);
            }
            (clipboard::PANEL_LABEL, tauri::WindowEvent::Focused(false)) => {
                let _ = window.hide();
            }
            _ => {}
        })
        .build(tauri::generate_context!())
        .expect("启动 NextWorkZone 失败")
        .run(|_, _| {});
}
