//! 网页中的右键菜单在 macOS 上用系统菜单显示（见 src/components/ContextMenu.tsx）。
//!
//! Tauri 自带的 popup 在菜单打开期间一直占用资源表，网页这时再修改菜单（例如把“加载中”
//! 换成加载完成的子菜单）会和它互相等待。这里取出菜单后立即释放资源表，再弹出菜单。

use nextworkzone_core::{Error, Result};
use tauri::menu::{ContextMenu, Menu};
use tauri::{LogicalPosition, Manager, ResourceId, Webview, Window};

/// 在窗口中的 (x, y)（逻辑像素）处弹出菜单，菜单关闭后返回。
#[tauri::command]
pub async fn menu_popup(webview: Webview, window: Window, rid: ResourceId, x: f64, y: f64) -> Result<()> {
    let menu = webview.resources_table().get::<Menu<tauri::Wry>>(rid).map_err(|e| Error::Other(e.to_string()))?;
    // 弹出菜单会在主线程上等到菜单关闭，这段时间不占用异步任务的线程
    tauri::async_runtime::spawn_blocking(move || menu.popup_at(window, LogicalPosition::new(x, y)))
        .await
        .map_err(|e| Error::Other(e.to_string()))?
        .map_err(|e| Error::Other(e.to_string()))
}
