//! 托盘（macOS 菜单栏）图标：关闭窗口后应用留在后台，从这里重新打开或直接执行常用操作。

use tauri::image::Image;
use tauri::menu::{MenuBuilder, MenuItem};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager};

/// 托盘菜单中需要界面处理的操作，载荷为菜单项 id（`quick-todo`、`search`、`page:<页面>`）。
pub const TRAY_EVENT: &str = "tray-action";

/// 托盘菜单中“暂停记录剪贴板”一项，暂停状态变化时更新文字。
struct ClipboardPauseItem(MenuItem<tauri::Wry>);

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let pause = MenuItem::with_id(app, "clipboard-pause", "暂停记录剪贴板", true, None::<&str>)?;
    let menu = MenuBuilder::new(app)
        .text("show", "打开 NextWorkZone")
        .separator()
        .text("capture", "快速记录…")
        .text("quick-todo", "记一条待办…")
        .text("search", "搜索…")
        .separator()
        .text("clipboard", "剪贴板…")
        .item(&pause)
        .separator()
        .text("page:home", "今天")
        .text("page:inbox", "收件箱")
        .text("page:todos", "待办")
        .text("page:notes", "笔记")
        .text("page:jira", "Jira")
        .text("page:activity", "动态")
        .text("page:weekly", "周报")
        .text("page:wiki", "Wiki")
        .separator()
        .text("page:settings", "设置…")
        .text("quit", "退出 NextWorkZone")
        .build()?;

    TrayIconBuilder::with_id("main")
        .icon(Image::from_bytes(include_bytes!("../icons/tray-template.png"))?)
        .icon_as_template(true)
        .tooltip("NextWorkZone")
        .menu(&menu)
        // macOS 习惯单击菜单栏图标弹出菜单；其他系统左键单击打开窗口，右键弹出菜单
        .show_menu_on_left_click(cfg!(target_os = "macos"))
        .on_menu_event(|app, event| match event.id().as_ref() {
            "quit" => app.exit(0),
            "show" => show_main(app),
            "capture" => crate::capture::toggle(app),
            "clipboard" => crate::clipboard::toggle(app),
            "clipboard-pause" => crate::clipboard::toggle_paused(app),
            action => {
                show_main(app);
                let _ = app.emit(TRAY_EVENT, action);
            }
        })
        .on_tray_icon_event(|tray, event| {
            #[cfg(not(target_os = "macos"))]
            if let tauri::tray::TrayIconEvent::Click {
                button: tauri::tray::MouseButton::Left,
                button_state: tauri::tray::MouseButtonState::Up,
                ..
            } = event
            {
                show_main(tray.app_handle());
            }
            #[cfg(target_os = "macos")]
            let _ = (tray, event);
        })
        .build(app)?;
    app.manage(ClipboardPauseItem(pause));
    Ok(())
}

pub fn update_clipboard_pause(app: &AppHandle, paused: bool) {
    if let Some(item) = app.try_state::<ClipboardPauseItem>() {
        let _ = item.0.set_text(if paused { "恢复记录剪贴板" } else { "暂停记录剪贴板" });
    }
}

/// 显示并聚焦主窗口（关闭窗口时只是隐藏了它）。
pub fn show_main(app: &AppHandle) {
    // 快速记录收起时可能隐藏了整个应用
    #[cfg(target_os = "macos")]
    let _ = app.show();
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}
