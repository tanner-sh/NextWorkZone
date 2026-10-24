//! Tauri 端的平台能力。

use std::path::Path;

use nextworkzone_app::{Host, Shortcut};
use nextworkzone_core::Result;
use serde_json::Value;
use tauri::{AppHandle, Emitter};
use tauri_plugin_notification::NotificationExt;
use tauri_plugin_opener::OpenerExt;

pub struct TauriHost(pub AppHandle);

impl Host for TauriHost {
    fn emit(&self, event: &str, payload: Value) {
        let _ = self.0.emit(event, payload);
    }

    fn notify(&self, title: &str, body: &str) {
        let _ = self.0.notification().builder().title(title).body(body).show();
    }

    fn open_path(&self, path: &Path) -> Result<()> {
        self.0.opener().open_path(path.to_string_lossy(), None::<&str>).map_err(std::io::Error::other)?;
        Ok(())
    }

    fn set_shortcut(&self, action: Shortcut, shortcut: &str) -> Result<()> {
        crate::shortcuts::set(&self.0, action, shortcut)
    }

    fn shortcut_error(&self, action: Shortcut) -> Option<String> {
        crate::shortcuts::error(action)
    }

    fn hide_clipboard_panel(&self, restore: bool) {
        crate::clipboard::hide(&self.0, restore);
    }

    fn clipboard_paused(&self, paused: bool) {
        crate::tray::update_clipboard_pause(&self.0, paused);
    }
}
