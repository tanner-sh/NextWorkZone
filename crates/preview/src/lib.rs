//! 附件预览：把表格（Excel、CSV）、Word 文档、文本文件转换为前端可以直接显示的内容。
//! 图片、PDF 由 WebView 直接显示，不经过这里。

use std::io::{Cursor, Read};

use calamine::{Data, Reader, open_workbook_auto_from_rs};
use quick_xml::Reader as XmlReader;
use quick_xml::events::Event;
use serde::Serialize;

/// 文本最多显示的字节数（日志文件可能很大）。
const MAX_TEXT_BYTES: usize = 2 * 1024 * 1024;
const MAX_ROWS: usize = 2000;
const MAX_COLS: usize = 80;
const MAX_SHEETS: usize = 30;
const MAX_PARAGRAPHS: usize = 5000;

#[derive(Debug, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Preview {
    #[serde(rename_all = "camelCase")]
    Text { text: String, truncated: bool, encoding: String },
    Sheet { sheets: Vec<Sheet> },
    #[serde(rename_all = "camelCase")]
    Document { paragraphs: Vec<String>, truncated: bool },
    #[serde(rename_all = "camelCase")]
    Archive { entries: Vec<ArchiveEntry>, truncated: bool },
    Unsupported { reason: String },
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ArchiveEntry {
    pub name: String,
    pub size: u64,
    pub dir: bool,
}

const MAX_ENTRIES: usize = 5000;

#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Sheet {
    pub name: String,
    pub rows: Vec<Vec<String>>,
    /// 实际的行数、列数（超过上限时只返回前面一部分）。
    pub total_rows: usize,
    pub total_cols: usize,
}

fn extension(filename: &str) -> String {
    filename.rsplit_once('.').map(|(_, ext)| ext.to_ascii_lowercase()).unwrap_or_default()
}

const TEXT_EXTENSIONS: &[&str] = &[
    "txt", "log", "out", "err", "trace", "md", "json", "xml", "yaml", "yml", "sql", "ini", "conf", "cfg", "properties",
    "java", "js", "ts", "tsx", "jsx", "py", "rs", "go", "c", "h", "cpp", "cs", "kt", "sh", "bat", "cmd", "ps1", "html",
    "htm", "css", "vue", "toml", "gradle", "jsp",
];

/// 能否预览（不下载内容，用于决定点击附件时打开预览还是直接用系统应用打开）。
pub fn can_preview(filename: &str, mime: &str) -> bool {
    let ext = extension(filename);
    matches!(ext.as_str(), "xlsx" | "xlsm" | "xlsb" | "xls" | "ods" | "csv" | "tsv" | "docx" | "zip" | "jar" | "war")
        || TEXT_EXTENSIONS.contains(&ext.as_str())
        || mime.starts_with("text/")
        || matches!(mime, "application/json" | "application/xml")
}

pub fn preview(filename: &str, mime: &str, bytes: &[u8]) -> Preview {
    let ext = extension(filename);
    match ext.as_str() {
        "xlsx" | "xlsm" | "xlsb" | "xls" | "ods" => workbook(bytes),
        "csv" | "tsv" => {
            let (text, _, _) = decode(bytes);
            let sep = if ext == "tsv" { '\t' } else { detect_separator(&text) };
            Preview::Sheet { sheets: vec![table_from_rows(filename, parse_delimited(&text, sep))] }
        }
        "docx" => docx(bytes),
        "zip" | "jar" | "war" => archive(bytes),
        "doc" | "ppt" | "pptx" | "pdf" => Preview::Unsupported { reason: "这种文件暂不支持在应用内预览".into() },
        _ if can_preview(filename, mime) || looks_textual(bytes) => {
            let (text, encoding, truncated) = decode(bytes);
            Preview::Text { text, truncated, encoding }
        }
        _ => Preview::Unsupported { reason: "这种文件暂不支持在应用内预览".into() },
    }
}

/// 开头没有空字节、大部分是可显示字符时当作文本。
fn looks_textual(bytes: &[u8]) -> bool {
    let head = &bytes[..bytes.len().min(8192)];
    !head.is_empty() && !head.contains(&0) && head.iter().filter(|b| **b < 0x09 || (**b > 0x0d && **b < 0x20)).count() * 100 < head.len()
}

/// 解码文本：UTF-8（含 BOM）、UTF-16（有 BOM 时），否则按 GB18030（国内系统导出的日志、CSV 常见）。
/// 返回文本、编码名称和是否截断。
fn decode(bytes: &[u8]) -> (String, String, bool) {
    let truncated = bytes.len() > MAX_TEXT_BYTES;
    let bytes = &bytes[..bytes.len().min(MAX_TEXT_BYTES)];
    if let Some((encoding, bom)) = encoding_rs::Encoding::for_bom(bytes) {
        let (text, _) = encoding.decode_without_bom_handling(&bytes[bom..]);
        return (text.into_owned(), encoding.name().to_string(), truncated);
    }
    // 截断可能切在多字节字符中间，只容许结尾处不完整
    match std::str::from_utf8(bytes) {
        Ok(text) => (text.to_string(), "UTF-8".into(), truncated),
        Err(e) if e.error_len().is_none() => (String::from_utf8_lossy(&bytes[..e.valid_up_to()]).into_owned(), "UTF-8".into(), truncated),
        Err(_) => {
            let (text, _, _) = encoding_rs::GB18030.decode(bytes);
            (text.into_owned(), "GB18030".into(), truncated)
        }
    }
}

fn workbook(bytes: &[u8]) -> Preview {
    let mut book = match open_workbook_auto_from_rs(Cursor::new(bytes.to_vec())) {
        Ok(book) => book,
        Err(e) => return Preview::Unsupported { reason: format!("无法读取表格：{e}") },
    };
    let names = book.sheet_names();
    let mut sheets = Vec::new();
    for name in names.into_iter().take(MAX_SHEETS) {
        let Ok(range) = book.worksheet_range(&name) else { continue };
        let (height, width) = range.get_size();
        let rows = range.rows().take(MAX_ROWS).map(|row| row.iter().take(MAX_COLS).map(cell_text).collect()).collect();
        sheets.push(Sheet { name, rows: trim_rows(rows), total_rows: height, total_cols: width });
    }
    if sheets.is_empty() {
        return Preview::Unsupported { reason: "表格中没有可显示的工作表".into() };
    }
    Preview::Sheet { sheets }
}

fn cell_text(cell: &Data) -> String {
    match cell {
        Data::Empty => String::new(),
        // 整数不显示小数点
        Data::Float(f) if f.fract() == 0.0 && f.abs() < 1e15 => format!("{}", *f as i64),
        Data::DateTime(d) => match d.as_datetime() {
            Some(t) if t.time() == chrono::NaiveTime::MIN => t.date().to_string(),
            Some(t) => t.format("%Y-%m-%d %H:%M:%S").to_string(),
            None => d.to_string(),
        },
        Data::Error(e) => format!("#{e:?}"),
        other => other.to_string(),
    }
}

/// 去掉末尾的空行和每行末尾的空单元格，减少空白。
fn trim_rows(mut rows: Vec<Vec<String>>) -> Vec<Vec<String>> {
    while rows.last().is_some_and(|r| r.iter().all(String::is_empty)) {
        rows.pop();
    }
    let width = rows.iter().map(|r| r.iter().rposition(|c| !c.is_empty()).map_or(0, |i| i + 1)).max().unwrap_or(0);
    for row in &mut rows {
        row.truncate(width);
    }
    rows
}

fn table_from_rows(filename: &str, rows: Vec<Vec<String>>) -> Sheet {
    let total_rows = rows.len();
    let total_cols = rows.iter().map(Vec::len).max().unwrap_or(0);
    let rows = rows.into_iter().take(MAX_ROWS).map(|r| r.into_iter().take(MAX_COLS).collect()).collect();
    Sheet { name: filename.to_string(), rows: trim_rows(rows), total_rows, total_cols }
}

/// 第一行里逗号、分号、制表符哪个多就用哪个。
fn detect_separator(text: &str) -> char {
    let first = text.lines().next().unwrap_or("");
    [',', ';', '\t'].into_iter().max_by_key(|c| first.matches(*c).count()).unwrap_or(',')
}

/// 解析 CSV：支持双引号包裹的字段（字段内可以有分隔符、换行和成对的双引号）。
fn parse_delimited(text: &str, sep: char) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut row = Vec::new();
    let mut field = String::new();
    let mut quoted = false;
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if quoted {
            match c {
                '"' if chars.peek() == Some(&'"') => {
                    field.push('"');
                    chars.next();
                }
                '"' => quoted = false,
                _ => field.push(c),
            }
            continue;
        }
        match c {
            '"' if field.is_empty() => quoted = true,
            '\r' => {}
            '\n' => {
                row.push(std::mem::take(&mut field));
                rows.push(std::mem::take(&mut row));
            }
            c if c == sep => row.push(std::mem::take(&mut field)),
            _ => field.push(c),
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }
    rows
}

/// 压缩包：列出其中的文件。
fn archive(bytes: &[u8]) -> Preview {
    let Ok(mut archive) = zip::ZipArchive::new(Cursor::new(bytes)) else {
        return Preview::Unsupported { reason: "无法读取压缩包".into() };
    };
    let total = archive.len();
    let entries = (0..total.min(MAX_ENTRIES))
        .filter_map(|i| {
            let file = archive.by_index_raw(i).ok()?;
            Some(ArchiveEntry { name: file.name().to_string(), size: file.size(), dir: file.is_dir() })
        })
        .collect();
    Preview::Archive { entries, truncated: total > MAX_ENTRIES }
}

/// Word 文档：按段落取出文字（表格中的每个单元格也是段落）。
fn docx(bytes: &[u8]) -> Preview {
    let xml = zip::ZipArchive::new(Cursor::new(bytes)).ok().and_then(|mut archive| {
        let mut file = archive.by_name("word/document.xml").ok()?;
        let mut xml = String::new();
        file.read_to_string(&mut xml).ok()?;
        Some(xml)
    });
    let Some(xml) = xml else { return Preview::Unsupported { reason: "无法读取 Word 文档".into() } };
    let mut reader = XmlReader::from_str(&xml);
    let mut paragraphs = Vec::new();
    let mut current = String::new();
    let mut in_text = false;
    loop {
        match reader.read_event() {
            Ok(Event::Start(e)) if e.name().into_inner() == "w:t" => in_text = true,
            Ok(Event::End(e)) if e.name().into_inner() == "w:t" => in_text = false,
            Ok(Event::Text(t)) if in_text => current.push_str(&t.into_inner()),
            Ok(Event::GeneralRef(r)) if in_text => {
                // &amp; 等实体
                current.push_str(match &*r.into_inner() {
                    "amp" => "&",
                    "lt" => "<",
                    "gt" => ">",
                    "quot" => "\"",
                    "apos" => "'",
                    _ => "",
                });
            }
            Ok(Event::Empty(e)) if e.name().into_inner() == "w:tab" => current.push('\t'),
            Ok(Event::Empty(e)) if e.name().into_inner() == "w:br" => current.push('\n'),
            Ok(Event::End(e)) if e.name().into_inner() == "w:p" => {
                paragraphs.push(std::mem::take(&mut current));
                if paragraphs.len() >= MAX_PARAGRAPHS {
                    return Preview::Document { paragraphs, truncated: true };
                }
            }
            Ok(Event::Eof) => break,
            Err(_) => return Preview::Unsupported { reason: "Word 文档格式有误".into() },
            _ => {}
        }
    }
    // 连续的空段落只保留一个
    paragraphs.dedup_by(|a, b| a.trim().is_empty() && b.trim().is_empty());
    Preview::Document { paragraphs, truncated: false }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn decodes_utf8_and_gbk() {
        let (text, enc, _) = decode("你好".as_bytes());
        assert_eq!((text.as_str(), enc.as_str()), ("你好", "UTF-8"));
        let (gbk, _, _) = encoding_rs::GBK.encode("报错信息");
        let (text, enc, _) = decode(&gbk);
        assert_eq!((text.as_str(), enc.as_str()), ("报错信息", "GB18030"));
        let (text, _, _) = decode(b"\xEF\xBB\xBFabc");
        assert_eq!(text, "abc");
    }

    #[test]
    fn parses_csv_with_quotes() {
        let rows = parse_delimited("a,b\n\"x,1\",\"say \"\"hi\"\"\"\n\"多\n行\",3\n", ',');
        assert_eq!(rows, vec![vec!["a", "b"], vec!["x,1", "say \"hi\""], vec!["多\n行", "3"]]);
        assert_eq!(detect_separator("a;b;c\n1;2;3"), ';');
    }

    #[test]
    fn previews_csv_as_sheet_and_logs_as_text() {
        let Preview::Sheet { sheets } = preview("data.csv", "", b"h1,h2\n1,2\n") else { panic!() };
        assert_eq!(sheets[0].rows, vec![vec!["h1", "h2"], vec!["1", "2"]]);
        assert!(matches!(preview("app.log", "", b"ERROR x"), Preview::Text { .. }));
        assert!(matches!(preview("a.bin", "", &[0, 1, 2, 3]), Preview::Unsupported { .. }));
    }

    #[test]
    fn extracts_docx_paragraphs() {
        let mut buf = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut buf);
            zip.start_file("word/document.xml", zip::write::SimpleFileOptions::default()).unwrap();
            zip.write_all(
                r#"<w:document><w:body><w:p><w:r><w:t>第一段</w:t></w:r><w:r><w:t xml:space="preserve"> A&amp;B</w:t></w:r></w:p><w:p></w:p><w:p></w:p><w:p><w:r><w:t>第二段</w:t></w:r></w:p></w:body></w:document>"#.as_bytes(),
            )
            .unwrap();
            zip.finish().unwrap();
        }
        let Preview::Document { paragraphs, .. } = preview("a.docx", "", buf.get_ref()) else { panic!() };
        assert_eq!(paragraphs, vec!["第一段 A&B", "", "第二段"]);
    }

    #[test]
    fn lists_zip_entries() {
        let mut buf = Cursor::new(Vec::new());
        {
            let mut zip = zip::ZipWriter::new(&mut buf);
            zip.add_directory("lib/", zip::write::SimpleFileOptions::default()).unwrap();
            zip.start_file("lib/补丁.class", zip::write::SimpleFileOptions::default()).unwrap();
            zip.write_all(b"abc").unwrap();
            zip.finish().unwrap();
        }
        let Preview::Archive { entries, .. } = preview("patch.zip", "", buf.get_ref()) else { panic!() };
        assert_eq!(entries.iter().map(|e| (e.name.as_str(), e.size, e.dir)).collect::<Vec<_>>(), vec![("lib/", 0, true), ("lib/补丁.class", 3, false)]);
    }

    #[test]
    fn trims_empty_cells() {
        let rows = trim_rows(vec![vec!["a".into(), "".into()], vec!["".into(), "".into()]]);
        assert_eq!(rows, vec![vec!["a".to_string()]]);
    }
}
