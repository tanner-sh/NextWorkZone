//! 小工具的通用设置（各工具自己的设置在各自的模块中）。

use nextworkzone_core::Result;
use tauri::State;

use crate::state::AppState;

/// 不在侧边栏显示的工具 id。
#[tauri::command]
pub fn tools_hidden(state: State<'_, AppState>) -> Vec<String> {
    state.config().tools.hidden
}

#[tauri::command]
pub fn tools_set_hidden(state: State<'_, AppState>, hidden: Vec<String>) -> Result<Vec<String>> {
    let mut config = state.config();
    config.tools.hidden = hidden;
    state.update_config(config.clone())?;
    Ok(config.tools.hidden)
}
