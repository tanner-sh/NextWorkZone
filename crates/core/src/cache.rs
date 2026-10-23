//! 简单的 JSON 文件缓存：界面先展示上次的结果，再在后台刷新。

use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::{Hash, Hasher};
use std::path::PathBuf;

use serde::Serialize;
use serde::de::DeserializeOwned;

pub struct Cache {
    dir: PathBuf,
}

impl Cache {
    pub fn new(dir: PathBuf) -> Self {
        Self { dir }
    }

    fn path(&self, key: &str) -> PathBuf {
        let mut hasher = DefaultHasher::new();
        key.hash(&mut hasher);
        self.dir.join(format!("{:016x}.json", hasher.finish()))
    }

    /// 缓存缺失或格式过期时返回 `None`。
    pub fn get<T: DeserializeOwned>(&self, key: &str) -> Option<T> {
        let text = fs::read_to_string(self.path(key)).ok()?;
        serde_json::from_str(&text).ok()
    }

    /// 写入失败只影响下次的加载速度，因此忽略错误。
    pub fn put<T: Serialize>(&self, key: &str, value: &T) {
        let Ok(text) = serde_json::to_string(value) else { return };
        let _ = fs::create_dir_all(&self.dir);
        let _ = fs::write(self.path(key), text);
    }
}
