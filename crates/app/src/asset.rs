//! 需要认证的图片和附件（Jira 附件、Wiki 内嵌图片、头像等），以及工作空间、剪贴板中的本机图片。
//!
//! 路径格式（各端的图片加载都使用它）：
//! - `ws/<图片 id>`：工作空间里的图片，直接从本地数据库读取；
//! - `<jira|confluence|gitlab>/<编码后的路径或完整地址>`：带上对应系统的凭据去取回内容。
//!   只允许访问已配置系统的地址，避免凭据被发往其他主机。

use nextworkzone_core::{Error, Result, Service};
use percent_encoding::percent_decode_str;

use crate::state::AppState;

/// 取回资源，返回内容和类型。
pub async fn fetch(state: &AppState, path: &str) -> Result<(Vec<u8>, Option<String>)> {
    let (service, target) = path
        .trim_start_matches('/')
        .split_once('/')
        .ok_or_else(|| Error::InvalidUrl(path.to_string()))?;
    let service = match service {
        "ws" => {
            let id = percent_decode_str(target).decode_utf8_lossy().into_owned();
            let workspace = state.workspace.clone();
            let found = tokio::task::spawn_blocking(move || workspace.asset(&id))
                .await
                .map_err(|e| Error::Other(e.to_string()))??;
            return found
                .map(|(mime, data)| (data, Some(mime)))
                .ok_or_else(|| Error::Other("图片尚未同步到本机".into()));
        }
        "jira" => Service::Jira,
        "confluence" => Service::Confluence,
        "gitlab" => Service::Gitlab,
        _ => return Err(Error::InvalidUrl(path.to_string())),
    };
    let target = percent_decode_str(target).decode_utf8_lossy().into_owned();
    let url = state.resolve_url(service, &target)?;
    state.fetch_web(service, &url).await
}
