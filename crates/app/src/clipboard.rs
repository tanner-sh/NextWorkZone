//! 剪贴板历史：在后台记录复制过的内容，把选中的条目写回剪贴板并粘贴到之前使用的应用。
//!
//! 面板窗口由各端自己实现：打开面板前调用 [`Clip::capture_target`] 记下位于前台的应用，
//! 收起面板由 [`Host::hide_clipboard_panel`](crate::host::Host::hide_clipboard_panel) 完成。

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use nextworkzone_clipboard::{Capture, ClipItem, ListQuery, Pinboard, Stats, Store, classify, privacy};
use nextworkzone_core::config::{ClipboardConfig, IgnoredApp};
use nextworkzone_core::{Error, Result};
use nextworkzone_desktop::apps::{self, AppInfo};
use nextworkzone_desktop::clipboard::{self as system, Clipboard, Image};
use nextworkzone_desktop::input::{self, PasteSupport};
use serde::Serialize;

use crate::host::Shortcut;
use crate::state::AppState;

/// 记录到新内容（或再次复制了已有内容）时发给所有窗口，载荷为 [`ClipItem`]。
pub const CHANGED_EVENT: &str = "clipboard-changed";
/// 设置或暂停状态变化时发给所有窗口。
pub const SETTINGS_EVENT: &str = "clipboard-settings";

/// 检查剪贴板是否变化的间隔。
const POLL: Duration = Duration::from_millis(300);
/// 自动清理过期历史的间隔。
const PRUNE_EVERY: Duration = Duration::from_secs(3600);

pub struct Clip {
    pub store: Arc<Store>,
    /// 后台监听与写入共用一个系统剪贴板句柄（Linux 上写入的内容由句柄持有，不能随用随建）。
    clipboard: Mutex<Option<Clipboard>>,
    /// 暂停记录到何时（毫秒时间戳）；0 表示未暂停，`i64::MAX` 表示直到手动恢复。
    paused_until: AtomicI64,
    /// 打开面板前位于前台的应用，粘贴到这里。
    target: Mutex<Option<AppInfo>>,
    /// 本应用写入剪贴板后的变化序号，监听时跳过，不当作新复制的内容。
    own_change: AtomicI64,
    /// 不提供变化序号的平台：本应用最近写入的文字。
    own_text: Mutex<Option<String>>,
}

impl Clip {
    pub fn open(dir: &Path) -> Result<Self> {
        Ok(Self {
            store: Arc::new(Store::open(dir)?),
            clipboard: Mutex::new(None),
            paused_until: AtomicI64::new(0),
            target: Mutex::new(None),
            own_change: AtomicI64::new(i64::MIN),
            own_text: Mutex::new(None),
        })
    }

    fn with_clipboard<T>(&self, f: impl FnOnce(&mut Clipboard) -> std::result::Result<T, String>) -> Result<T> {
        let mut guard = self.clipboard.lock().unwrap();
        if guard.is_none() {
            *guard = Some(Clipboard::new().map_err(|e| Error::Other(format!("无法访问剪贴板：{e}")))?);
        }
        f(guard.as_mut().unwrap()).map_err(|e| Error::Other(format!("剪贴板读写失败：{e}")))
    }

    pub fn paused(&self) -> Option<i64> {
        let until = self.paused_until.load(Ordering::Relaxed);
        (until > chrono::Utc::now().timestamp_millis()).then_some(until)
    }

    /// 打开面板前调用：记下位于前台的应用（粘贴到这里），返回它的名称（本应用时为 `None`）。
    pub fn capture_target(&self) -> Option<String> {
        let target = apps::frontmost();
        let name = target.as_ref().filter(|t| t.pid != Some(std::process::id())).map(|t| t.name.clone());
        *self.target.lock().unwrap() = target;
        name
    }

    /// 打开面板前位于前台的应用。
    pub fn target(&self) -> Option<AppInfo> {
        self.target.lock().unwrap().clone()
    }
}

/// 启动后台记录线程。
pub fn start(state: Arc<AppState>) -> std::io::Result<()> {
    std::thread::Builder::new().name("clipboard-watch".into()).spawn(move || watch(state))?;
    Ok(())
}

// ---------- 后台记录 ----------

fn watch(state: Arc<AppState>) {
    let clip = &state.clip;
    let mut last_count = system::change_count();
    let mut last_text = if last_count.is_none() { clip.with_clipboard(|c| Ok(c.read_text())).ok().flatten() } else { None };
    let mut last_prune: Option<Instant> = None;
    loop {
        std::thread::sleep(POLL);
        // 配置在需要时才读取：空闲时每次轮询只比较变化序号，不复制整份配置
        if last_prune.is_none_or(|t| t.elapsed() > PRUNE_EVERY) {
            last_prune = Some(Instant::now());
            let config = state.config().tools.clipboard;
            if let Ok(removed) = clip.store.prune(config.keep_days, config.max_items)
                && removed > 0
            {
                state.emit(SETTINGS_EVENT, ());
            }
        }

        // 先判断是否有变化（很便宜），有变化才读取内容
        match system::change_count() {
            Some(count) => {
                if Some(count) == last_count {
                    continue;
                }
                last_count = Some(count);
                if count == clip.own_change.load(Ordering::Relaxed) {
                    continue;
                }
            }
            None => {
                let text = clip.with_clipboard(|c| Ok(c.read_text())).ok().flatten();
                if text == last_text {
                    continue;
                }
                last_text = text.clone();
                if text.is_some() && *clip.own_text.lock().unwrap() == text {
                    continue;
                }
            }
        }
        let config = state.config().tools.clipboard;
        if !config.enabled || clip.paused().is_some() || system::is_concealed() {
            continue;
        }
        let source = apps::frontmost();
        if let Some(source) = &source
            && ignored(&config, &source.id)
        {
            continue;
        }
        if let Some(item) = record(clip, &config, source) {
            state.emit(CHANGED_EVENT, item);
        }
    }
}

/// 是否不记录这个应用中复制的内容。
fn ignored(config: &ClipboardConfig, app_id: &str) -> bool {
    privacy::DEFAULT_IGNORED_APPS.iter().any(|(id, _)| id.eq_ignore_ascii_case(app_id)) || config.ignored_apps.iter().any(|a| a.id.eq_ignore_ascii_case(app_id))
}

fn record(clip: &Clip, config: &ClipboardConfig, source: Option<AppInfo>) -> Option<ClipItem> {
    let snapshot = clip.with_clipboard(|c| Ok(c.read(config.save_images))).ok()?;
    if snapshot.is_empty() {
        return None;
    }
    if config.skip_secrets && snapshot.text.as_deref().is_some_and(privacy::looks_secret) {
        return None;
    }
    let max_bytes = config.max_image_mb as usize * 1024 * 1024;
    let image = snapshot.image.filter(|i| max_bytes == 0 || i.rgba.len() <= max_bytes).map(|i| (i.width as u32, i.height as u32, i.rgba));
    if let Some(source) = &source
        && !clip.store.has_app(&source.id).unwrap_or(true)
    {
        let _ = clip.store.save_app(&source.id, &source.name, apps::icon_png(source, 64).as_deref());
    }
    let capture = Capture {
        text: snapshot.text,
        html: snapshot.html,
        image,
        files: snapshot.files.iter().map(|p| p.to_string_lossy().into_owned()).collect(),
        app: source.map(|s| (s.id, s.name)),
    };
    clip.store.add(capture).ok().flatten().map(|(item, _)| item)
}

// ---------- 粘贴 ----------

/// 等待目标应用回到前台后模拟粘贴（最多等 1 秒）。
fn paste_into(target: Option<AppInfo>) {
    std::thread::spawn(move || {
        let started = Instant::now();
        if let Some(pid) = target.and_then(|t| t.pid) {
            while started.elapsed() < Duration::from_secs(1) && apps::frontmost().and_then(|f| f.pid) != Some(pid) {
                std::thread::sleep(Duration::from_millis(15));
            }
        }
        // 留一点时间让目标窗口的输入框重新获得焦点
        std::thread::sleep(Duration::from_millis(60));
        let _ = input::send_paste();
    });
}

// ---------- 写回剪贴板 ----------

/// 把条目写入系统剪贴板。`plain` 只写纯文本；`edited` 是编辑后的文字（代替原内容）。
fn write(clip: &Clip, ids: &[String], plain: bool, edited: Option<String>) -> Result<()> {
    let mut contents = Vec::new();
    for id in ids {
        contents.push(clip.store.content(id)?.ok_or_else(|| Error::Other("条目已被删除".into()))?);
    }
    enum Payload {
        Text(String, Option<String>),
        Image(String),
        Files(Vec<PathBuf>),
    }
    let payload = match (edited, contents.as_slice()) {
        (Some(text), _) => Payload::Text(text, None),
        (None, [one]) if one.kind == classify::IMAGE => Payload::Image(one.id.clone()),
        (None, [one]) if one.kind == classify::FILE => Payload::Files(one.files.iter().map(PathBuf::from).collect()),
        (None, [one]) => Payload::Text(one.text.clone(), one.html.clone().filter(|_| !plain)),
        // 多条一起粘贴：全是文件时合并为文件列表，否则把文字按行拼接（图片不参与）
        (None, many) if many.iter().all(|c| c.kind == classify::FILE) => Payload::Files(many.iter().flat_map(|c| c.files.iter().map(PathBuf::from)).collect()),
        (None, many) => Payload::Text(
            many.iter().filter(|c| c.kind != classify::IMAGE).map(|c| if c.kind == classify::FILE { c.files.join("\n") } else { c.text.clone() }).collect::<Vec<_>>().join("\n"),
            None,
        ),
    };
    let image = match &payload {
        Payload::Image(id) => Some(clip.store.load_image(id)?),
        _ => None,
    };
    clip.with_clipboard(|c| match (&payload, image) {
        (_, Some((width, height, rgba))) => c.write_image(&Image { width: width as usize, height: height as usize, rgba }),
        (Payload::Text(text, html), _) => c.write_text(text, html.as_deref()),
        (Payload::Files(files), _) => c.write_files(files),
        (Payload::Image(_), None) => Ok(()),
    })?;
    if let Some(count) = system::change_count() {
        clip.own_change.store(count, Ordering::Relaxed);
    } else if let Payload::Text(text, _) = &payload {
        *clip.own_text.lock().unwrap() = Some(text.clone());
    }
    clip.store.touch(ids)
}

// ---------- 命令 ----------

/// 数据库操作放到阻塞线程中执行：同步命令运行在主线程上，历史多时查询会卡住界面。
async fn run<T: Send + 'static>(clip: &Clip, f: impl FnOnce(&Store) -> Result<T> + Send + 'static) -> Result<T> {
    let store = clip.store.clone();
    tokio::task::spawn_blocking(move || f(&store)).await.map_err(|e| Error::Other(e.to_string()))?
}

/// 粘贴到打开面板前使用的应用：写入剪贴板、收起面板、交还焦点，有权限时模拟按下粘贴快捷键。
/// 返回 `pasted`（已粘贴）或 `copied`（只复制了，需要用户自己粘贴）。
pub async fn clip_paste(state: &AppState, ids: Vec<String>, plain: Option<bool>, edited: Option<String>) -> Result<String> {
    let clip = &state.clip;
    let config = state.config().tools.clipboard;
    write(clip, &ids, plain.unwrap_or(config.plain_text), edited)?;
    state.emit(SETTINGS_EVENT, ());
    let target = clip.target();
    state.host.hide_clipboard_panel(true);
    if config.auto_paste && input::paste_support() == PasteSupport::Ready {
        paste_into(target);
        Ok("pasted".into())
    } else {
        Ok("copied".into())
    }
}

/// 只复制到剪贴板（不收起面板、不粘贴）。
pub async fn clip_copy(state: &AppState, ids: Vec<String>, plain: Option<bool>, edited: Option<String>) -> Result<()> {
    write(&state.clip, &ids, plain.unwrap_or(false), edited)?;
    state.emit(SETTINGS_EVENT, ());
    Ok(())
}

pub async fn clip_list(state: &AppState, query: ListQuery) -> Result<Vec<ClipItem>> {
    run(&state.clip, move |store| store.list(&query)).await
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipText {
    text: String,
    html: Option<String>,
}

/// 文字条目的完整内容（列表中只有开头一部分）。
pub async fn clip_text(state: &AppState, id: String) -> Result<ClipText> {
    let content = run(&state.clip, move |store| store.content(&id)).await?.ok_or_else(|| Error::Other("条目已被删除".into()))?;
    Ok(ClipText { text: content.text, html: content.html })
}

pub async fn clip_delete(state: &AppState, ids: Vec<String>) -> Result<()> {
    run(&state.clip, move |store| store.delete(&ids)).await?;
    state.emit(SETTINGS_EVENT, ());
    Ok(())
}

pub async fn clip_clear(state: &AppState) -> Result<usize> {
    let removed = run(&state.clip, |store| store.clear_history()).await?;
    state.emit(SETTINGS_EVENT, ());
    Ok(removed)
}

pub async fn clip_set_pinboard(state: &AppState, ids: Vec<String>, pinboard: Option<String>) -> Result<()> {
    run(&state.clip, move |store| store.set_pinboard(&ids, pinboard.as_deref())).await?;
    state.emit(SETTINGS_EVENT, ());
    Ok(())
}

pub async fn clip_rename(state: &AppState, id: String, title: String) -> Result<Option<ClipItem>> {
    let item = run(&state.clip, move |store| store.rename(&id, &title)).await?;
    state.emit(SETTINGS_EVENT, ());
    Ok(item)
}

pub async fn clip_update_text(state: &AppState, id: String, text: String) -> Result<Option<ClipItem>> {
    let item = run(&state.clip, move |store| store.update_text(&id, &text)).await?;
    state.emit(SETTINGS_EVENT, ());
    Ok(item)
}

pub async fn clip_pinboards(state: &AppState) -> Result<Vec<Pinboard>> {
    run(&state.clip, |store| store.pinboards()).await
}

pub async fn clip_save_pinboard(state: &AppState, id: Option<String>, name: String, color: String) -> Result<Pinboard> {
    let board = run(&state.clip, move |store| store.save_pinboard(id.as_deref(), &name, &color)).await?;
    state.emit(SETTINGS_EVENT, ());
    Ok(board)
}

pub async fn clip_delete_pinboard(state: &AppState, id: String) -> Result<()> {
    run(&state.clip, move |store| store.delete_pinboard(&id)).await?;
    state.emit(SETTINGS_EVENT, ());
    Ok(())
}

pub async fn clip_order_pinboards(state: &AppState, ids: Vec<String>) -> Result<()> {
    run(&state.clip, move |store| store.order_pinboards(&ids)).await?;
    state.emit(SETTINGS_EVENT, ());
    Ok(())
}

pub async fn clip_apps(state: &AppState) -> Result<Vec<nextworkzone_clipboard::AppCount>> {
    run(&state.clip, |store| store.apps()).await
}

/// 本机问题库中的问题（剪贴板中出现的问题 key 显示概要和状态）。
pub async fn clip_issues(state: &AppState, keys: Vec<String>) -> Result<Vec<nextworkzone_jira::index::IssueHit>> {
    let index = state.issue_index.clone();
    tokio::task::spawn_blocking(move || index.by_keys(&keys)).await.map_err(|e| Error::Other(e.to_string()))?
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ClipSettings {
    config: ClipboardConfig,
    /// 内置的忽略列表（始终生效）。
    builtin_ignored: Vec<IgnoredApp>,
    stats: Stats,
    /// `ready` / `needsPermission` / `unsupported`
    paste_support: String,
    /// 不能自动粘贴的原因。
    paste_note: Option<String>,
    /// 暂停记录到何时；`i64::MAX` 表示直到手动恢复。
    paused_until: Option<i64>,
    shortcut_error: Option<String>,
    /// 历史保存的位置。
    data_dir: String,
}

fn settings(state: &AppState) -> Result<ClipSettings> {
    let clip = &state.clip;
    let (paste_support, paste_note) = match input::paste_support() {
        PasteSupport::Ready => ("ready", None),
        PasteSupport::NeedsPermission => ("needsPermission", None),
        PasteSupport::Unsupported(reason) => ("unsupported", Some(reason)),
    };
    Ok(ClipSettings {
        config: state.config().tools.clipboard,
        builtin_ignored: privacy::DEFAULT_IGNORED_APPS
            .iter()
            .filter(|(id, _)| cfg!(windows) == id.ends_with(".exe"))
            .map(|(id, name)| IgnoredApp { id: id.to_string(), name: name.to_string() })
            .collect(),
        stats: clip.store.stats()?,
        paste_support: paste_support.into(),
        paste_note,
        paused_until: clip.paused(),
        shortcut_error: state.host.shortcut_error(Shortcut::Clipboard),
        data_dir: clip.store.dir().to_string_lossy().into_owned(),
    })
}

pub async fn clip_settings(state: &AppState) -> Result<ClipSettings> {
    settings(state)
}

/// 保存设置：快捷键或开关变化时重新注册快捷键（失败时不保存），并按新的保留规则清理历史。
pub async fn clip_save_settings(state: &AppState, config: ClipboardConfig) -> Result<ClipSettings> {
    let mut app_config = state.config();
    let old = &app_config.tools.clipboard;
    let shortcut = |c: &ClipboardConfig| if c.enabled { c.shortcut.trim().to_string() } else { String::new() };
    if shortcut(old) != shortcut(&config) {
        state.host.set_shortcut(Shortcut::Clipboard, &shortcut(&config))?;
    }
    if !config.enabled {
        state.host.hide_clipboard_panel(false);
    }
    state.clip.store.prune(config.keep_days, config.max_items)?;
    app_config.tools.clipboard = config;
    state.update_config(app_config)?;
    state.emit(SETTINGS_EVENT, ());
    settings(state)
}

/// 暂停记录 `minutes` 分钟；0 表示恢复，负数表示直到手动恢复。
pub async fn clip_pause(state: &AppState, minutes: i64) -> Result<ClipSettings> {
    set_paused(state, minutes);
    settings(state)
}

pub fn set_paused(state: &AppState, minutes: i64) {
    let until = match minutes {
        0 => 0,
        m if m < 0 => i64::MAX,
        m => chrono::Utc::now().timestamp_millis() + m * 60_000,
    };
    state.clip.paused_until.store(until, Ordering::Relaxed);
    state.host.clipboard_paused(until != 0);
    state.emit(SETTINGS_EVENT, ());
}

/// 暂停或恢复（托盘菜单）。
pub fn toggle_paused(state: &AppState) {
    set_paused(state, if state.clip.paused().is_some() { 0 } else { -1 });
}

/// 请求自动粘贴需要的系统权限。
pub async fn clip_request_permission() {
    input::request_permission();
}

/// 最近记录过的来源应用中尚未忽略的（设置页中选择要忽略的应用）。
pub async fn clip_ignore_candidates(state: &AppState) -> Result<Vec<IgnoredApp>> {
    let config = state.config().tools.clipboard;
    Ok(run(&state.clip, |store| store.apps())
        .await?
        .into_iter()
        .filter(|a| !ignored(&config, &a.id))
        .map(|a| IgnoredApp { id: a.id, name: a.name })
        .collect())
}

// ---------- 拖到其他应用 ----------

/// 标记为刚刚使用（拖到其他应用后），下次打开面板时排在最前面。
pub async fn clip_touch(state: &AppState, ids: Vec<String>) -> Result<()> {
    run(&state.clip, move |store| store.touch(&ids)).await
}

/// 拖动预览图的边长（逻辑像素）。
const DRAG_PREVIEW: u32 = 96;

/// 拖到其他应用的文件和预览图（PNG）。
pub struct DragFiles {
    pub paths: Vec<PathBuf>,
    pub preview: Vec<u8>,
}

/// 把图片、文件条目准备为可以拖到其他应用（访达、聊天、邮件等）的文件。文字由界面直接处理。
///
/// 图片先导出到临时文件夹，文件名带上复制时间；文件条目中已经不存在的路径会被跳过。
/// `fallback_icon` 是没有缩略图时使用的预览图（应用图标）。
pub fn drag_files(clip: &Clip, ids: &[String], fallback_icon: &[u8]) -> Result<DragFiles> {
    let mut paths = Vec::new();
    let mut preview: Option<Vec<u8>> = None;
    let export_dir = std::env::temp_dir().join("NextWorkZone").join("drag");
    for id in ids {
        let Some(item) = clip.store.item(id)? else { continue };
        match item.kind.as_str() {
            classify::IMAGE => {
                std::fs::create_dir_all(&export_dir)?;
                let time = chrono::DateTime::from_timestamp_millis(item.copied_at)
                    .map(|t| t.with_timezone(&chrono::Local).format("%Y-%m-%d %H.%M.%S").to_string())
                    .unwrap_or_default();
                let name = if item.title.trim().is_empty() { format!("剪贴板图片 {time}") } else { sanitize_file_name(&item.title) };
                let target = export_dir.join(format!("{name}.png"));
                std::fs::copy(clip.store.image_path(id), &target).map_err(|e| Error::Other(format!("图片已丢失：{e}")))?;
                if preview.is_none() {
                    preview = std::fs::read(clip.store.thumb_path(id)).ok().and_then(|png| nextworkzone_clipboard::shrink_png(&png, DRAG_PREVIEW));
                }
                paths.push(target);
            }
            classify::FILE => {
                for file in item.files.iter().map(PathBuf::from).filter(|p| p.exists()) {
                    if preview.is_none() {
                        preview = apps::file_icon_png(&file.to_string_lossy(), 64);
                    }
                    paths.push(file);
                }
            }
            _ => {}
        }
    }
    if paths.is_empty() {
        return Err(Error::Other("没有可以拖出的文件（原文件可能已被移动或删除）".into()));
    }
    let preview = preview.or_else(|| nextworkzone_clipboard::shrink_png(fallback_icon, 64)).unwrap_or_default();
    Ok(DragFiles { paths, preview })
}

/// 去掉文件名中不允许的字符。
fn sanitize_file_name(name: &str) -> String {
    let cleaned: String = name.trim().chars().map(|c| if matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') || c.is_control() { '_' } else { c }).collect();
    cleaned.chars().take(80).collect()
}
