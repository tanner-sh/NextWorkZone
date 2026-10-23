use serde::{Serialize, Serializer};

use crate::Service;

pub type Result<T, E = Error> = std::result::Result<T, E>;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("尚未配置 {} 的地址", .0.label())]
    NotConfigured(Service),

    #[error("尚未设置 {} 的 Token", .0.label())]
    MissingToken(Service),

    #[error("需要先网页登录 {}，才能访问附件和图片", .0.label())]
    SessionRequired(Service),

    #[error("无效的地址：{0}")]
    InvalidUrl(String),

    #[error("认证失败（HTTP {status}），请检查 Token 是否有效或已过期")]
    Unauthorized { status: u16 },

    #[error("没有权限执行此操作：{body}")]
    Forbidden { body: String },

    #[error("请求失败（HTTP {status}）：{body}")]
    Http { status: u16, body: String },

    #[error("内容已被他人修改：{0}")]
    Conflict(String),

    #[error("{0}")]
    Other(String),

    #[error("网络错误：{}", error_chain(.0))]
    Network(#[from] reqwest::Error),

    #[error("钥匙串访问失败：{0}")]
    Keyring(#[from] keyring::Error),

    #[error("文件读写失败：{0}")]
    Io(#[from] std::io::Error),

    #[error("数据格式错误：{0}")]
    Json(#[from] serde_json::Error),
}

/// reqwest 的错误信息只有最外层（例如“error sending request”），把底层原因也拼上，便于排查。
fn error_chain(error: &reqwest::Error) -> String {
    let mut text = error.to_string();
    let mut source = std::error::Error::source(error);
    while let Some(cause) = source {
        text.push('：');
        text.push_str(&cause.to_string());
        source = cause.source();
    }
    text
}

// 前端只需要可读的错误信息，因此序列化为字符串。
impl Serialize for Error {
    fn serialize<S: Serializer>(&self, serializer: S) -> std::result::Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.to_string())
    }
}
