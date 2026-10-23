//! 模拟按下粘贴快捷键，把内容直接粘贴到之前使用的应用中。

/// 能否模拟粘贴。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PasteSupport {
    Ready,
    /// 需要用户授权（macOS 的“辅助功能”权限）。
    NeedsPermission,
    /// 当前环境做不到，附带原因。
    Unsupported(String),
}

pub fn paste_support() -> PasteSupport {
    #[cfg(target_os = "macos")]
    return if crate::macos::accessibility_trusted(false) { PasteSupport::Ready } else { PasteSupport::NeedsPermission };
    #[cfg(windows)]
    return PasteSupport::Ready;
    #[cfg(not(any(target_os = "macos", windows)))]
    return match linux::tool() {
        Some(_) => PasteSupport::Ready,
        None if linux::wayland() => PasteSupport::Unsupported("需要安装 wtype 才能自动粘贴".into()),
        None => PasteSupport::Unsupported("需要安装 xdotool 才能自动粘贴".into()),
    };
}

/// 请求授权：macOS 上弹出系统的“辅助功能”授权提示并打开对应的设置页面。
pub fn request_permission() {
    #[cfg(target_os = "macos")]
    {
        crate::macos::accessibility_trusted(true);
        let _ = std::process::Command::new("open")
            .arg("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            .spawn();
    }
}

/// 鼠标左键当前是否按着（开始系统拖放前检查：松开后再开始会失败）。平台不支持查询时返回 true。
pub fn left_button_down() -> bool {
    #[cfg(target_os = "macos")]
    return crate::macos::left_button_down();
    #[cfg(windows)]
    return crate::windows::left_button_down();
    #[cfg(not(any(target_os = "macos", windows)))]
    true
}

/// 向当前前台应用发送粘贴快捷键（macOS 上是 ⌘V，其他平台是 Ctrl+V）。
pub fn send_paste() -> Result<(), String> {
    #[cfg(target_os = "macos")]
    return crate::macos::send_paste();
    #[cfg(windows)]
    return crate::windows::send_paste();
    #[cfg(not(any(target_os = "macos", windows)))]
    return linux::send_paste();
}

#[cfg(not(any(target_os = "macos", windows)))]
mod linux {
    use std::process::Command;

    pub fn wayland() -> bool {
        std::env::var_os("WAYLAND_DISPLAY").is_some()
    }

    fn installed(program: &str) -> bool {
        std::env::var_os("PATH").is_some_and(|paths| std::env::split_paths(&paths).any(|dir| dir.join(program).is_file()))
    }

    /// 可用的按键模拟工具：Wayland 下用 wtype，X11 下用 xdotool。
    pub fn tool() -> Option<&'static str> {
        let tool = if wayland() { "wtype" } else { "xdotool" };
        installed(tool).then_some(tool)
    }

    pub fn send_paste() -> Result<(), String> {
        let status = match tool() {
            Some("wtype") => Command::new("wtype").args(["-M", "ctrl", "v", "-m", "ctrl"]).status(),
            Some(_) => Command::new("xdotool").args(["key", "--clearmodifiers", "ctrl+v"]).status(),
            None => return Err("没有可用的按键模拟工具".into()),
        };
        match status {
            Ok(s) if s.success() => Ok(()),
            Ok(s) => Err(format!("模拟粘贴失败：{s}")),
            Err(e) => Err(e.to_string()),
        }
    }
}
