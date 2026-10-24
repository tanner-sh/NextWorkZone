//! 与操作系统打交道的桌面能力，供各个小工具使用：剪贴板读写与变化检测、前台应用与应用图标、模拟粘贴。
//!
//! 每项能力在 macOS、Windows、Linux 上分别实现；某个平台做不到时返回 `None` 或说明原因，
//! 由调用方降级处理（例如不能模拟按键时只复制、不自动粘贴）。

pub mod apps;
pub mod clipboard;
pub mod input;

#[cfg(target_os = "macos")]
mod macos;
#[cfg(windows)]
mod windows;
