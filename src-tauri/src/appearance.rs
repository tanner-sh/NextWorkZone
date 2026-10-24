//! 窗口外观：macOS 26 起主窗口侧栏使用 Liquid Glass 面板，剪贴板面板和快速记录窗口整窗使用 Liquid Glass；
//! 更早的系统沿用毛玻璃材质。界面通过 [`ui_glass`] 得知是否使用了 Liquid Glass，相应调整样式。

use std::sync::atomic::{AtomicBool, Ordering};

use nextworkzone_desktop::window::GlassSidebar;
use tauri::window::{Effect, EffectState, EffectsBuilder};
use tauri::{AppHandle, Manager};

/// 侧栏玻璃面板的位置和圆角，与 styles.css 中的 --sidebar-inset、--sidebar-width、--sidebar-radius 一致。
const SIDEBAR: GlassSidebar = GlassSidebar { inset: 8.0, width: 220.0, radius: 16.0 };

static GLASS: AtomicBool = AtomicBool::new(false);

/// 是否使用了 Liquid Glass。
pub fn glass() -> bool {
    GLASS.load(Ordering::Relaxed)
}

pub fn setup(app: &AppHandle) {
    let Some(window) = app.get_webview_window("main") else { return };
    let glass = window.ns_window().is_ok_and(|w| nextworkzone_desktop::window::glass_sidebar(w, SIDEBAR));
    GLASS.store(glass, Ordering::Relaxed);
    if !glass {
        // 不支持 Liquid Glass：整个窗口背后放侧栏材质，内容区由网页画不透明背景
        let _ = window.set_effects(EffectsBuilder::new().effect(Effect::Sidebar).state(EffectState::FollowsWindowActiveState).build());
    }
}

/// 浮动窗口（剪贴板面板、快速记录）的材质：优先 Liquid Glass，旧系统用 `fallback`（没有时不加材质）。
pub fn floating_effects(fallback: Option<Effect>, radius: f64) -> tauri::utils::config::WindowEffectsConfig {
    EffectsBuilder::new().effects([Effect::LiquidGlassRegular].into_iter().chain(fallback)).state(EffectState::Active).radius(radius).build()
}

#[tauri::command]
pub fn ui_glass() -> bool {
    glass()
}
