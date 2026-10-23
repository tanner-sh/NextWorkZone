use serde::{Deserialize, Serialize};

/// 工作台接入的外部系统。
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Service {
    Jira,
    Confluence,
    Gitlab,
}

impl Service {
    pub const ALL: [Service; 3] = [Service::Jira, Service::Confluence, Service::Gitlab];

    /// 用作配置键、钥匙串账户名等的稳定标识。
    pub fn key(self) -> &'static str {
        match self {
            Service::Jira => "jira",
            Service::Confluence => "confluence",
            Service::Gitlab => "gitlab",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Service::Jira => "Jira",
            Service::Confluence => "Wiki",
            Service::Gitlab => "GitLab",
        }
    }
}

/// 连接测试的结果：当前 Token 对应的用户以及服务端版本。
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionInfo {
    pub service: Service,
    pub username: String,
    pub display_name: String,
    pub server_version: Option<String>,
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;

    use super::Service;

    #[test]
    fn deserializes_as_map_key() {
        let map: HashMap<Service, String> =
            serde_json::from_str(r#"{"jira":"a","confluence":"b","gitlab":"c"}"#).unwrap();
        assert_eq!(map[&Service::Confluence], "b");
    }
}
