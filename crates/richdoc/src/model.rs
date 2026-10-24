//! 文档模型：块（段落、标题、列表、表格……）由行内内容（文字、图片、提及……）组成。
//!
//! 序列化为 JSON 交给界面（`t` 为类型），字段尽量短，并省略默认值。

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Doc {
    pub blocks: Vec<Block>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "camelCase")]
pub enum Block {
    Para {
        inl: Vec<Inline>,
    },
    Heading {
        level: u8,
        inl: Vec<Inline>,
        /// 锚点（目录跳转）
        #[serde(default, skip_serializing_if = "Option::is_none")]
        id: Option<String>,
    },
    List {
        ordered: bool,
        #[serde(default, skip_serializing_if = "is_zero")]
        start: u32,
        items: Vec<Item>,
    },
    Quote {
        blocks: Vec<Block>,
    },
    Code {
        #[serde(default, skip_serializing_if = "String::is_empty")]
        lang: String,
        text: String,
    },
    Table {
        rows: Vec<Row>,
    },
    Rule,
    /// 信息框、面板、折叠块等：`kind` 为 info / note / warning / tip / panel / expand
    Panel {
        kind: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        title: String,
        blocks: Vec<Block>,
    },
    /// Wiki 编辑时不可编辑的内容（宏等），原文在编辑会话的 fragments 中
    Opaque(Opaque),
    /// Wiki 编辑时页面布局等容器的起止（原文在 fragments 中）
    Marker {
        n: usize,
    },
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Item {
    /// 任务列表的勾选状态
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub task: Option<Task>,
    pub blocks: Vec<Block>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Task {
    pub done: bool,
    /// Wiki 页面任务的 id（勾选后写回页面）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Row {
    pub cells: Vec<Cell>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Cell {
    #[serde(default, skip_serializing_if = "is_false")]
    pub head: bool,
    pub blocks: Vec<Block>,
    #[serde(default = "one", skip_serializing_if = "is_one")]
    pub colspan: u32,
    #[serde(default = "one", skip_serializing_if = "is_one")]
    pub rowspan: u32,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Opaque {
    /// 原文在 fragments 中的下标
    pub n: usize,
    /// 显示的说明文字（多行）
    pub label: String,
    #[serde(default, skip_serializing_if = "is_false")]
    pub block: bool,
    /// 图片：附件文件名或地址
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image: Option<String>,
    /// 提到的用户（userkey）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub user: Option<String>,
    /// Jira 宏引用的问题键
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issue: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "camelCase")]
pub enum Inline {
    Text {
        s: String,
        #[serde(default, skip_serializing_if = "is_zero16")]
        m: u16,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        link: Option<String>,
        /// 文字颜色（#rrggbb）
        #[serde(default, skip_serializing_if = "Option::is_none")]
        color: Option<String>,
    },
    Image {
        src: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        alt: String,
        /// 放大查看时用的原图（缩略图外层链接等）
        #[serde(default, skip_serializing_if = "Option::is_none")]
        full: Option<String>,
        /// Jira 附件图片的文件名（写回 wiki 标记时用 `!文件名!`）
        #[serde(default, skip_serializing_if = "Option::is_none")]
        file: Option<String>,
        #[serde(default, skip_serializing_if = "is_false")]
        thumb: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        width: Option<u32>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        height: Option<u32>,
    },
    Br,
    /// Jira 问题（显示实时的概要和状态）
    Issue {
        key: String,
    },
    /// 状态标签（Confluence 的 status 宏等）
    Status {
        text: String,
        /// grey / blue / green / yellow / red
        #[serde(default, skip_serializing_if = "String::is_empty")]
        color: String,
    },
    /// @提及：`user` 为用户名
    Mention {
        name: String,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        user: String,
    },
    /// 待上传的附件（Jira 编辑器中拖入的文件）
    Attachment {
        file: String,
    },
    Opaque(Opaque),
    Marker {
        n: usize,
    },
}

/// 文字格式（按位组合）。
pub mod marks {
    pub const BOLD: u16 = 1;
    pub const ITALIC: u16 = 2;
    pub const UNDERLINE: u16 = 4;
    pub const STRIKE: u16 = 8;
    pub const CODE: u16 = 16;
    pub const SUP: u16 = 32;
    pub const SUB: u16 = 64;
    /// 高亮（搜索关键词、Wiki 的 highlight 等）
    pub const MARK: u16 = 128;
}

impl Inline {
    pub fn text(s: impl Into<String>) -> Self {
        Inline::Text { s: s.into(), m: 0, link: None, color: None }
    }
}

impl Block {
    pub fn para(inl: Vec<Inline>) -> Self {
        Block::Para { inl }
    }
}

impl Doc {
    /// 纯文本（搜索、摘要）。
    pub fn plain_text(&self) -> String {
        let mut out = String::new();
        for b in &self.blocks {
            block_text(b, &mut out);
        }
        out.trim().to_string()
    }
}

fn block_text(b: &Block, out: &mut String) {
    match b {
        Block::Para { inl } | Block::Heading { inl, .. } => {
            inline_text(inl, out);
            out.push('\n');
        }
        Block::List { items, .. } => {
            for item in items {
                for b in &item.blocks {
                    block_text(b, out);
                }
            }
        }
        Block::Quote { blocks } | Block::Panel { blocks, .. } => blocks.iter().for_each(|b| block_text(b, out)),
        Block::Code { text, .. } => {
            out.push_str(text);
            out.push('\n');
        }
        Block::Table { rows } => {
            for row in rows {
                for cell in &row.cells {
                    cell.blocks.iter().for_each(|b| block_text(b, out));
                }
            }
        }
        Block::Opaque(o) => {
            out.push_str(&o.label);
            out.push('\n');
        }
        Block::Rule | Block::Marker { .. } => {}
    }
}

pub(crate) fn inline_text(inl: &[Inline], out: &mut String) {
    for i in inl {
        match i {
            Inline::Text { s, .. } => out.push_str(s),
            Inline::Br => out.push('\n'),
            Inline::Issue { key } => out.push_str(key),
            Inline::Status { text, .. } => out.push_str(text),
            Inline::Mention { name, .. } => {
                out.push('@');
                out.push_str(name);
            }
            Inline::Attachment { file } => out.push_str(file),
            Inline::Opaque(o) => out.push_str(&o.label),
            Inline::Image { .. } | Inline::Marker { .. } => {}
        }
    }
}

fn is_zero(n: &u32) -> bool {
    *n == 0
}
fn is_zero16(n: &u16) -> bool {
    *n == 0
}
fn is_one(n: &u32) -> bool {
    *n == 1
}
fn one() -> u32 {
    1
}
fn is_false(b: &bool) -> bool {
    !*b
}
