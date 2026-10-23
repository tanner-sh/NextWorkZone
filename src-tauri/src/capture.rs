//! 快速记录：在任何应用中按全局快捷键弹出一个小窗口，记一条待办、一段日记或存入收件箱。
//! 窗口启动时就创建好并隐藏，按下快捷键时立即显示；失去焦点或记完后隐藏。

use tauri::{AppHandle, Emitter, Manager, WebviewUrl, WebviewWindowBuilder};
use tauri_plugin_clipboard_manager::ClipboardExt;

use crate::shortcuts::{self, Action};
use crate::state::AppState;

pub const CAPTURE_LABEL: &str = "capture";
/// 显示窗口时发给快速记录界面的事件（界面据此清空输入、读取剪贴板）。
const OPEN_EVENT: &str = "capture-open";

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    WebviewWindowBuilder::new(app, CAPTURE_LABEL, WebviewUrl::App("index.html#capture".into()))
        .title("快速记录")
        .inner_size(620.0, 340.0)
        .resizable(false)
        .decorations(false)
        .transparent(true)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible_on_all_workspaces(true)
        .visible(false)
        .center()
        .build()?;
    let shortcut = app.state::<AppState>().config().workspace.capture_shortcut;
    shortcuts::init(app, Action::Capture, &shortcut);
    Ok(())
}

/// 显示或隐藏快速记录窗口。
pub fn toggle(app: &AppHandle) {
    let Some(window) = app.get_webview_window(CAPTURE_LABEL) else { return };
    if window.is_visible().unwrap_or(false) && window.is_focused().unwrap_or(false) {
        hide(app);
        return;
    }
    #[cfg(target_os = "macos")]
    let _ = app.show();
    let _ = window.center();
    let _ = window.show();
    let _ = window.set_focus();
    let _ = window.emit(OPEN_EVENT, ());
}

/// 隐藏快速记录窗口。主窗口没有显示时把整个应用隐藏，焦点回到之前使用的应用。
pub fn hide(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(CAPTURE_LABEL) {
        let _ = window.hide();
    }
    #[cfg(target_os = "macos")]
    if !app.get_webview_window("main").is_some_and(|w| w.is_visible().unwrap_or(false)) {
        let _ = app.hide();
    }
}

#[tauri::command]
pub fn capture_hide(app: AppHandle) {
    hide(&app);
}

/// 剪贴板中的文字（快速记录可以一键存入收件箱）。
#[tauri::command]
pub fn capture_clipboard(app: AppHandle) -> Option<String> {
    app.clipboard().read_text().ok().map(|t| t.trim().to_string()).filter(|t| !t.is_empty())
}

/// 剪贴板中的原样文字：右键菜单的“粘贴”（WebView 读取剪贴板会弹出系统确认）。
#[tauri::command]
pub fn clipboard_read_text(app: AppHandle) -> Option<String> {
    app.clipboard().read_text().ok().filter(|t| !t.is_empty())
}
