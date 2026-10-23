//! 系统剪贴板：读取当前内容（文本、HTML、图片、文件）、写入，以及检测内容是否变化。

use std::path::PathBuf;

/// 剪贴板中的一份内容。同一份内容可能同时带有多种格式（例如网页上复制的文字同时有纯文本和 HTML）。
#[derive(Default)]
pub struct Snapshot {
    pub text: Option<String>,
    pub html: Option<String>,
    pub image: Option<Image>,
    pub files: Vec<PathBuf>,
}

impl Snapshot {
    pub fn is_empty(&self) -> bool {
        self.text.is_none() && self.image.is_none() && self.files.is_empty()
    }
}

/// 未压缩的 RGBA 像素。
pub struct Image {
    pub width: usize,
    pub height: usize,
    pub rgba: Vec<u8>,
}

/// 系统剪贴板的句柄。创建一次后反复使用。
pub struct Clipboard {
    inner: arboard::Clipboard,
}

impl Clipboard {
    pub fn new() -> Result<Self, String> {
        arboard::Clipboard::new().map(|inner| Self { inner }).map_err(|e| e.to_string())
    }

    /// 读取当前内容。`with_image` 为 false 时不读图片（图片解码较慢）。
    pub fn read(&mut self, with_image: bool) -> Snapshot {
        let files = self.inner.get().file_list().unwrap_or_default();
        if !files.is_empty() {
            return Snapshot { files, ..Default::default() };
        }
        let text = self.inner.get().text().ok().filter(|t| !t.trim().is_empty());
        let html = text.as_ref().and_then(|_| self.inner.get().html().ok()).filter(|h| !h.trim().is_empty());
        // 有文字时以文字为准：表格软件复制单元格时还会附带一张渲染出来的图片
        let image = if text.is_none() && with_image {
            self.inner.get().image().ok().filter(|i| i.width > 0 && i.height > 0).map(|i| Image {
                width: i.width,
                height: i.height,
                rgba: i.bytes.into_owned(),
            })
        } else {
            None
        };
        Snapshot { text, html, image, files }
    }

    /// 只读文字（用于不支持变化序号的平台比较内容是否变化）。
    pub fn read_text(&mut self) -> Option<String> {
        self.inner.get().text().ok()
    }

    /// 写入文字；有 HTML 时同时写入，粘贴到支持格式的应用会保留格式。
    pub fn write_text(&mut self, text: &str, html: Option<&str>) -> Result<(), String> {
        match html {
            Some(html) => self.inner.set_html(html, Some(text)),
            None => self.inner.set_text(text),
        }
        .map_err(|e| e.to_string())
    }

    pub fn write_image(&mut self, image: &Image) -> Result<(), String> {
        self.inner
            .set_image(arboard::ImageData { width: image.width, height: image.height, bytes: (&image.rgba[..]).into() })
            .map_err(|e| e.to_string())
    }

    pub fn write_files(&mut self, files: &[PathBuf]) -> Result<(), String> {
        self.inner.set().file_list(files).map_err(|e| e.to_string())
    }
}

/// 剪贴板的变化序号，每次有应用写入剪贴板都会增加。
/// 平台不提供时返回 `None`，调用方需要比较内容来判断是否变化。
pub fn change_count() -> Option<i64> {
    #[cfg(target_os = "macos")]
    return Some(crate::macos::change_count());
    #[cfg(windows)]
    return Some(crate::windows::change_count());
    #[cfg(not(any(target_os = "macos", windows)))]
    None
}

/// 当前内容被写入方标记为敏感或临时内容（密码管理器复制的密码、自动生成的临时内容等），不应记录到历史中。
///
/// macOS 遵循 nspasteboard.org 的约定；Windows 遵循剪贴板历史的排除格式。
pub fn is_concealed() -> bool {
    #[cfg(target_os = "macos")]
    return crate::macos::is_concealed();
    #[cfg(windows)]
    return crate::windows::is_concealed();
    #[cfg(not(any(target_os = "macos", windows)))]
    false
}
