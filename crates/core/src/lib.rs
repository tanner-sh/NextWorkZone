//! NextWorkZone 的公共基础：服务标识、配置、HTTP 客户端、凭据存储与统一错误类型。
//! 各系统适配器（jira / confluence / gitlab）只依赖本 crate，不依赖 Tauri。

pub mod cache;
pub mod config;
pub mod error;
pub mod http;
pub mod secrets;
pub mod service;

pub use config::{AppConfig, Endpoint};
pub use error::{Error, Result};
pub use service::{ConnectionInfo, Service};
