//! 窗口的系统级行为。

use std::ffi::c_void;

/// 让浮动窗口可以出现在全屏应用之上，并在所有桌面（空间）中显示。
///
/// `ns_window` 是 macOS 上窗口的 `NSWindow` 指针；其他平台不需要处理。
pub fn float_over_fullscreen(ns_window: *mut c_void) {
    #[cfg(target_os = "macos")]
    crate::macos::float_over_fullscreen(ns_window);
    #[cfg(not(target_os = "macos"))]
    let _ = ns_window;
}

/// 显示浮动窗口并让它接收键盘输入，同时激活应用，但不把应用的其他窗口（例如主窗口）带到前面。
///
/// 默认的激活方式会把应用的所有窗口都提到最前，挡住用户原来在用的应用。返回 false 表示平台不支持，
/// 调用方改用普通的显示和聚焦。
pub fn focus_alone(ns_window: *mut c_void) -> bool {
    #[cfg(target_os = "macos")]
    return crate::macos::focus_alone(ns_window);
    #[cfg(not(target_os = "macos"))]
    {
        let _ = ns_window;
        false
    }
}

/// 主窗口侧栏的玻璃面板：贴着窗口左侧、上下留出 `inset` 的圆角面板，放在网页内容后面，
/// 网页把这块区域留成透明即可显示出来。
#[derive(Debug, Clone, Copy)]
pub struct GlassSidebar {
    pub inset: f64,
    pub width: f64,
    pub radius: f64,
}

/// 在窗口中放入侧栏的 Liquid Glass 面板。返回 false 表示系统不支持（macOS 26 以前或其他平台），
/// 调用方改用其他材质或不透明背景。
pub fn glass_sidebar(ns_window: *mut c_void, sidebar: GlassSidebar) -> bool {
    #[cfg(target_os = "macos")]
    return crate::macos::glass_sidebar(ns_window, sidebar);
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (ns_window, sidebar);
        false
    }
}
