//! 各平台界面共用的应用层：运行期状态 [`AppState`]、全部业务命令（经 [`dispatch`] 按名称调用）、
//! 后台同步与剪贴板记录。窗口、托盘、快捷键、通知等平台能力由各端实现 [`Host`]。

pub mod asset;
pub mod clipboard;
pub mod commands;
mod dispatch;
pub mod host;
pub mod state;

use std::sync::Arc;

pub use dispatch::dispatch;
pub use host::{Host, Shortcut};
pub use state::{AppState, Paths};

/// 启动后台任务：网页会话保活、工作空间同步、问题库与 Wiki 库同步、提醒，以及剪贴板记录线程。
/// 需要在 tokio 运行时中调用。
pub fn start_background(state: &Arc<AppState>) -> std::io::Result<()> {
    tokio::spawn(commands::session::keep_alive_loop(state.clone()));
    tokio::spawn(commands::workspace::sync_loop(state.clone()));
    tokio::spawn(commands::jira_index::sync_loop(state.clone()));
    tokio::spawn(commands::wiki::sync_loop(state.clone()));
    tokio::spawn(commands::inbox::alert_loop(state.clone()));
    clipboard::start(state.clone())
}
