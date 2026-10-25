use std::sync::Arc;
use nextworkzone_core::{Error, Result};
use nextworkzone_jira::index::IssueIndex;

pub(crate) async fn blocking<T: Send + 'static>(index: &Arc<IssueIndex>, f: impl FnOnce(&IssueIndex) -> Result<T> + Send + 'static) -> Result<T> {
    let index = index.clone();
    tokio::task::spawn_blocking(move || f(&index)).await.map_err(|e| Error::Other(e.to_string()))?
}
