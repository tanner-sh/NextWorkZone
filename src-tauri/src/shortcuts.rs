//! 全局快捷键：快速记录、剪贴板等功能各自登记一个快捷键，在这里统一注册，互不影响。

use std::collections::HashMap;
use std::sync::Mutex;

use nextworkzone_core::{Error, Result};
use tauri::AppHandle;
use tauri_plugin_global_shortcut::{GlobalShortcutExt, ShortcutState};

pub use nextworkzone_app::Shortcut as Action;

fn run(action: Action, app: &AppHandle) {
    match action {
        Action::Capture => crate::capture::toggle(app),
        Action::Clipboard => crate::clipboard::toggle(app),
    }
}

#[derive(Default)]
struct Registry {
    /// 已注册的快捷键。
    bound: HashMap<Action, String>,
    /// 注册失败的原因（例如已被其他应用占用），设置页中显示。
    errors: HashMap<Action, String>,
}

static REGISTRY: Mutex<Option<Registry>> = Mutex::new(None);

fn with<T>(f: impl FnOnce(&mut Registry) -> T) -> T {
    f(REGISTRY.lock().unwrap().get_or_insert_with(Registry::default))
}

/// 启动时注册；失败只记录原因，不影响启动。
pub fn init(app: &AppHandle, action: Action, shortcut: &str) {
    let result = set(app, action, shortcut);
    with(|r| match result {
        Ok(()) => r.errors.remove(&action),
        Err(e) => r.errors.insert(action, e.to_string()),
    });
}

/// 把功能的快捷键改为 `shortcut`（为空表示不使用）。新快捷键注册失败时保留原来的并返回错误。
pub fn set(app: &AppHandle, action: Action, shortcut: &str) -> Result<()> {
    let shortcut = shortcut.trim();
    let manager = app.global_shortcut();
    if let Some(other) = with(|r| r.bound.iter().find(|(a, s)| **a != action && s.eq_ignore_ascii_case(shortcut)).map(|(a, _)| *a))
        && !shortcut.is_empty()
    {
        return Err(Error::Other(format!("快捷键已被“{}”使用", other.label())));
    }
    let old = with(|r| r.bound.remove(&action));
    if let Some(old) = &old {
        let _ = manager.unregister(old.as_str());
    }
    if shortcut.is_empty() {
        with(|r| r.errors.remove(&action));
        return Ok(());
    }
    let registered = manager.on_shortcut(shortcut, move |app, _, event| {
        if event.state == ShortcutState::Pressed {
            run(action, app);
        }
    });
    match registered {
        Ok(()) => {
            with(|r| {
                r.bound.insert(action, shortcut.to_string());
                r.errors.remove(&action);
            });
            Ok(())
        }
        Err(e) => {
            // 恢复原来的快捷键
            if let Some(old) = old
                && manager.on_shortcut(old.as_str(), move |app, _, event| {
                    if event.state == ShortcutState::Pressed {
                        run(action, app);
                    }
                })
                .is_ok()
            {
                with(|r| r.bound.insert(action, old));
            }
            Err(Error::Other(format!("无法使用快捷键 {shortcut}：{e}（可能已被其他应用占用）")))
        }
    }
}

pub fn error(action: Action) -> Option<String> {
    with(|r| r.errors.get(&action).cloned())
}
