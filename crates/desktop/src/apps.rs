//! 正在使用的应用：取得前台应用、把焦点交还给它、读取应用图标。

/// 一个正在运行的应用。
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppInfo {
    /// 稳定的标识：macOS 上是 Bundle ID，Windows 上是可执行文件名（小写）。
    pub id: String,
    /// 显示名称。
    pub name: String,
    /// 应用所在路径（macOS 上是 .app 包，Windows 上是可执行文件），用于读取图标。
    pub path: Option<String>,
    pub pid: Option<u32>,
    /// Windows 上的前台窗口句柄，用于把焦点交还给原来的窗口。
    pub window: Option<isize>,
}

/// 当前位于前台的应用。平台不支持时返回 `None`。
pub fn frontmost() -> Option<AppInfo> {
    #[cfg(target_os = "macos")]
    return crate::macos::frontmost();
    #[cfg(windows)]
    return crate::windows::frontmost();
    #[cfg(not(any(target_os = "macos", windows)))]
    None
}

/// 把应用切换到前台；做不到时返回 false。
pub fn activate(app: &AppInfo) -> bool {
    #[cfg(target_os = "macos")]
    return crate::macos::activate(app);
    #[cfg(windows)]
    return crate::windows::activate(app);
    #[cfg(not(any(target_os = "macos", windows)))]
    {
        let _ = app;
        false
    }
}

/// 应用图标的 PNG 数据，边长约为 `size` 像素。平台不支持时返回 `None`。
pub fn icon_png(app: &AppInfo, size: u32) -> Option<Vec<u8>> {
    file_icon_png(app.path.as_deref()?, size)
}

/// 文件或文件夹在系统中的图标（PNG），边长约为 `size` 像素。平台不支持时返回 `None`。
pub fn file_icon_png(path: &str, size: u32) -> Option<Vec<u8>> {
    #[cfg(target_os = "macos")]
    return crate::macos::icon_png(path, size);
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (path, size);
        None
    }
}
