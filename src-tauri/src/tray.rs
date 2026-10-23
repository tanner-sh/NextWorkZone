//! 托盘（macOS 菜单栏）图标：关闭窗口后应用留在后台，从这里重新打开或直接执行常用操作。

use tauri::image::Image;
use tauri::menu::MenuBuilder;
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Emitter, Manager};

/// 托盘菜单中需要界面处理的操作，载荷为菜单项 id（`quick-todo`、`search`、`page:<页面>`）。
pub const TRAY_EVENT: &str = "tray-action";

pub fn setup(app: &AppHandle) -> tauri::Result<()> {
    let menu = MenuBuilder::new(app)
        .text("show", "打开 NextWorkZone")
        .separator()
        .text("quick-todo", "记一条待办…")
        .text("search", "搜索…")
        .separator()
        .text("page:home", "今天")
        .text("page:todos", "待办")
        .text("page:notes", "笔记")
        .text("page:jira", "我的问题")
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
    Ok(())
}

/// 显示并聚焦主窗口（关闭窗口时只是隐藏了它）。
pub fn show_main(app: &AppHandle) {
    if let Some(window) = app.get_webview_window("main") {
        let _ = window.unminimize();
        let _ = window.show();
        let _ = window.set_focus();
    }
}
