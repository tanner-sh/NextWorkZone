//! 平台能力：各端（Tauri、macOS 原生界面）实现 [`Host`]，应用层通过它发事件、发通知、注册快捷键。

use std::path::Path;

use nextworkzone_core::Result;
use serde_json::Value;

/// 使用全局快捷键的功能。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Shortcut {
    Capture,
    Clipboard,
}

impl Shortcut {
    pub fn label(self) -> &'static str {
        match self {
            Shortcut::Capture => "快速记录",
            Shortcut::Clipboard => "剪贴板",
        }
    }
}

pub trait Host: Send + Sync + 'static {
    /// 把事件发给界面（所有窗口）。
    fn emit(&self, event: &str, payload: Value);

    /// 系统通知。
    fn notify(&self, title: &str, body: &str);

    /// 用系统默认程序打开文件。
    fn open_path(&self, path: &Path) -> Result<()>;

    /// 把功能的全局快捷键改为 `shortcut`（为空表示不使用）。失败时保留原来的并返回错误。
    fn set_shortcut(&self, action: Shortcut, shortcut: &str) -> Result<()>;

    /// 快捷键注册失败的原因（例如已被其他应用占用）。
    fn shortcut_error(&self, action: Shortcut) -> Option<String>;

    /// 收起剪贴板面板；`restore` 为 true 时把焦点交还给打开面板前使用的应用。
    fn hide_clipboard_panel(&self, restore: bool);

    /// 剪贴板记录暂停或恢复（例如更新托盘菜单的文字）。
    fn clipboard_paused(&self, paused: bool);
}
