//! 剪贴板面板：按全局快捷键从屏幕底部弹出，选中后直接粘贴到之前使用的应用。记录与粘贴在 [`nextworkzone_app::clipboard`]。
//!
//! 面板窗口启动时就创建好并隐藏，按下快捷键时立即显示在鼠标所在的屏幕上。

use std::sync::Arc;

use nextworkzone_app::AppState;
use nextworkzone_app::clipboard::drag_files;
use nextworkzone_core::{Error, Result};
use nextworkzone_desktop::apps;
use nextworkzone_desktop::input;
use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, PhysicalSize, State, WebviewUrl, WebviewWindowBuilder};

use crate::shortcuts::{self, Action};

pub const PANEL_LABEL: &str = "clipboard";
/// 显示面板时发给面板的事件，载荷为 [`OpenInfo`]。
const OPEN_EVENT: &str = "clipboard-open";

/// 面板高度与离屏幕边缘的距离（逻辑像素）。
const PANEL_HEIGHT: f64 = 340.0;
const PANEL_MARGIN: f64 = 8.0;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenInfo {
    /// 将要粘贴到的应用名称。
    target: Option<String>,
}

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let builder = WebviewWindowBuilder::new(app, PANEL_LABEL, WebviewUrl::App("index.html#clipboard".into()))
        .title("剪贴板")
        .inner_size(1200.0, PANEL_HEIGHT)
        .resizable(false)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .always_on_top(true)
        .skip_taskbar(true)
        .visible_on_all_workspaces(true)
        .visible(false)
        // 面板不接收拖入的文件；关掉后卡片可以用网页拖放拖到其他应用（Windows 上两者冲突）
        .disable_drag_drop_handler();
    // Windows 上面板背景使用系统的亚克力材质；Linux 上没有，界面改用不透明背景
    #[cfg(windows)]
    let builder = builder.effects(tauri::window::EffectsBuilder::new().effect(tauri::window::Effect::Acrylic).build());
    builder.build()?;

    let config = app.state::<Arc<AppState>>().config().tools.clipboard;
    shortcuts::init(app, Action::Clipboard, if config.enabled { &config.shortcut } else { "" });
    Ok(())
}

// ---------- 面板 ----------

/// 显示或隐藏面板。
pub fn toggle(app: &AppHandle) {
    let Some(window) = app.get_webview_window(PANEL_LABEL) else { return };
    if window.is_visible().unwrap_or(false) {
        hide(app, true);
        return;
    }
    let state = app.state::<Arc<AppState>>();
    if !state.config().tools.clipboard.enabled {
        return;
    }
    let target_name = state.clip.capture_target();
    place(app, &window);
    let _ = window.show();
    let _ = window.set_focus();
    let _ = window.emit(OPEN_EVENT, OpenInfo { target: target_name });
}

/// 把面板放到鼠标所在屏幕的底部，宽度铺满可用区域。
fn place(app: &AppHandle, window: &tauri::WebviewWindow) {
    let monitor = app
        .cursor_position()
        .ok()
        .and_then(|p| app.monitor_from_point(p.x, p.y).ok().flatten())
        .or_else(|| window.primary_monitor().ok().flatten());
    let Some(monitor) = monitor else { return };
    let scale = monitor.scale_factor();
    let area = monitor.work_area();
    let margin = (PANEL_MARGIN * scale).round() as i32;
    let width = (area.size.width as i32 - margin * 2).max(400) as u32;
    let height = (PANEL_HEIGHT * scale).round() as u32;
    let _ = window.set_size(PhysicalSize::new(width, height));
    let _ = window.set_position(PhysicalPosition::new(area.position.x + margin, area.position.y + area.size.height as i32 - height as i32 - margin));
}

/// 隐藏面板；`restore` 为 true 时把焦点交还给打开面板前使用的应用。
pub fn hide(app: &AppHandle, restore: bool) {
    if let Some(window) = app.get_webview_window(PANEL_LABEL) {
        let _ = window.hide();
    }
    if !restore {
        return;
    }
    let main = app.get_webview_window("main");
    let main_visible = main.as_ref().is_some_and(|w| w.is_visible().unwrap_or(false));
    let target = app.state::<Arc<AppState>>().clip.target();
    match target {
        // 从本应用打开的面板：回到主窗口
        Some(t) if t.pid == Some(std::process::id()) => {
            if let Some(main) = main.filter(|_| main_visible) {
                let _ = main.set_focus();
            }
        }
        target => {
            if let Some(t) = target {
                apps::activate(&t);
            }
        }
    }
}

#[tauri::command]
pub fn clip_hide(app: AppHandle, restore: bool) {
    hide(&app, restore);
}

/// 从面板跳到主窗口中打开（例如打开问题、进入剪贴板管理页）；载荷格式同托盘菜单事件，交给主窗口处理。
#[tauri::command]
pub fn clip_open_main(app: AppHandle, target: String) {
    hide(&app, false);
    crate::tray::show_main(&app);
    let _ = app.emit(crate::tray::TRAY_EVENT, target);
}

/// 把图片、文件条目作为文件拖到其他应用（文件管理器、聊天、邮件等）。文字由界面直接用网页拖放处理。
#[tauri::command]
pub fn clip_drag(app: AppHandle, window: tauri::WebviewWindow, state: State<'_, Arc<AppState>>, ids: Vec<String>) -> Result<()> {
    let files = drag_files(&state.clip, &ids, include_bytes!("../icons/128x128.png"))?;
    let handle = app.clone();
    let on_drop = move |result: drag::DragResult, _: drag::CursorPosition| {
        if matches!(result, drag::DragResult::Dropped) {
            let _ = handle.state::<Arc<AppState>>().clip.store.touch(&ids);
        }
    };
    let (paths, preview) = (files.paths, files.preview);
    // 拖动必须在主线程开始（此时鼠标仍按着）
    let target = window.clone();
    window
        .run_on_main_thread(move || {
            #[cfg(target_os = "linux")]
            let source = target.gtk_window();
            #[cfg(target_os = "linux")]
            let Ok(source) = source else { return };
            #[cfg(target_os = "linux")]
            let source = &source;
            #[cfg(not(target_os = "linux"))]
            let source = &target;
            // 鼠标已经松开时系统不会开始拖放（drag 在这种情况下会 panic），直接放弃这次拖动
            if !input::left_button_down() {
                return;
            }
            let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                drag::start_drag(source, drag::DragItem::Files(paths), drag::Image::Raw(preview), on_drop, drag::Options::default())
            }));
        })
        .map_err(|e| Error::Other(e.to_string()))
}
