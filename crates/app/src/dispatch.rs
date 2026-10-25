//! 统一的命令入口：各端界面按名称调用命令，参数和结果都是 JSON（参数名为 camelCase）。
//!
//! Tauri 前端和 macOS 原生界面调用的是同一组命令，新增命令只需要在这里登记一次。

use std::sync::Arc;

use nextworkzone_core::{Error, Result};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::commands::*;
use crate::state::AppState;

/// 取出参数；没有传的参数按 `null` 处理（对应 `Option` 为 `None`）。
fn arg<T: DeserializeOwned>(args: &Value, name: &str) -> Result<T> {
    let value = args.get(name).cloned().unwrap_or(Value::Null);
    serde_json::from_value(value).map_err(|e| Error::Other(format!("参数 {name} 格式不正确：{e}")))
}

fn json(value: impl Serialize) -> Result<Value> {
    Ok(serde_json::to_value(value)?)
}

/// 执行命令 `cmd`。
pub async fn dispatch(state: &Arc<AppState>, cmd: &str, args: Value) -> Result<Value> {
    match cmd {
        "global_search" => json(search::global_search(state, arg(&args, "query")?, arg(&args, "options")?).await?),
        "web_access_status" => json(session::web_access_status(state).await?),
        "web_login_info" => json(session::web_login_info(state, arg(&args, "service")?).await?),
        "web_login_finish" => json(session::web_login_finish(state, arg(&args, "service")?, arg(&args, "url")?, arg(&args, "cookie")?).await?),
        "web_logout" => json(session::web_logout(state, arg(&args, "service")?).await?),
        _ => Err(Error::Other(format!("未知的命令：{cmd}"))),
    }
}
