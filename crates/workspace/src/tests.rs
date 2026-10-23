use std::path::Path;

use super::*;

fn open(dir: &Path, name: &str) -> Workspace {
    Workspace::open(&dir.join(name)).unwrap()
}

fn todo(title: &str) -> TodoInput {
    TodoInput { title: title.into(), ..Default::default() }
}

fn note(title: &str, content: &str) -> DocInput {
    DocInput { kind: "note".into(), title: title.into(), content: content.into(), ..Default::default() }
}

fn issue(key: &str, summary: &str) -> AssignedIssue {
    AssignedIssue { key: key.into(), summary: summary.into(), due: None }
}

#[test]
fn todo_lifecycle() {
    let dir = tempfile::tempdir().unwrap();
    let ws = open(dir.path(), "a.db");
    let a = ws.save_todo(todo("写周报")).unwrap();
    let b = ws.save_todo(todo("评审 MR")).unwrap();
    // 新建的排在最前
    assert_eq!(ws.todos().unwrap().iter().map(|t| t.title.as_str()).collect::<Vec<_>>(), ["评审 MR", "写周报"]);

    let done = ws.set_todo_done(&a.id, true).unwrap();
    assert!(done.done && done.completed_at.is_some());
    let undone = ws.save_todo(TodoInput { id: Some(a.id.clone()), title: "写周报".into(), ..Default::default() }).unwrap();
    assert!(!undone.done && undone.completed_at.is_none());

    ws.delete_todo(&b.id).unwrap();
    assert_eq!(ws.todos().unwrap().len(), 1);
}

#[test]
fn jira_todos_follow_assigned_issues() {
    let dir = tempfile::tempdir().unwrap();
    let ws = open(dir.path(), "a.db");
    let r = ws.sync_jira_todos(&[issue("ABC-1", "修复导出"), issue("ABC-2", "优化查询")]).unwrap();
    assert_eq!(r.added, 2);

    // 概要变化时，没改过标题的待办跟随；改过标题的保留
    let t2 = ws.todo(&jira_todo_id("ABC-2")).unwrap().unwrap();
    ws.save_todo(TodoInput { id: Some(t2.id.clone()), title: "我自己的说法".into(), ref_system: t2.ref_system, ref_key: t2.ref_key, ref_title: t2.ref_title, ..Default::default() }).unwrap();
    ws.sync_jira_todos(&[issue("ABC-1", "修复导出（新）"), issue("ABC-2", "优化查询（新）")]).unwrap();
    assert_eq!(ws.todo(&jira_todo_id("ABC-1")).unwrap().unwrap().title, "修复导出（新）");
    assert_eq!(ws.todo(&jira_todo_id("ABC-2")).unwrap().unwrap().title, "我自己的说法");

    // ABC-1 不再分配给我 → 自动完成；再分配回来 → 恢复
    let r = ws.sync_jira_todos(&[issue("ABC-2", "优化查询（新）")]).unwrap();
    assert_eq!(r.completed, 1);
    assert!(ws.todo(&jira_todo_id("ABC-1")).unwrap().unwrap().done);
    let r = ws.sync_jira_todos(&[issue("ABC-1", "修复导出（新）"), issue("ABC-2", "优化查询（新）")]).unwrap();
    assert_eq!(r.reopened, 1);

    // 手动删除的不会被加回来
    ws.delete_todo(&jira_todo_id("ABC-2")).unwrap();
    let r = ws.sync_jira_todos(&[issue("ABC-1", "修复导出（新）"), issue("ABC-2", "优化查询（新）")]).unwrap();
    assert_eq!(r.added, 0);
    assert_eq!(ws.todos().unwrap().len(), 1);
}

#[test]
fn wiki_todos_are_separate_from_jira() {
    let dir = tempfile::tempdir().unwrap();
    let ws = open(dir.path(), "a.db");
    ws.sync_jira_todos(&[issue("ABC-1", "修复导出")]).unwrap();
    let task = AssignedWikiTask { page_id: "9".into(), page_title: "会议纪要".into(), task_id: "2".into(), text: "整理方案".into(), due: Some("2026-11-01".into()) };
    let r = ws.sync_wiki_todos(std::slice::from_ref(&task)).unwrap();
    assert_eq!(r.added, 1);
    let t = ws.todo(&wiki_todo_id("9", "2")).unwrap().unwrap();
    assert_eq!((t.title.as_str(), t.ref_system.as_deref(), t.ref_key.as_deref()), ("整理方案", Some("wiki"), Some("9")));
    assert_eq!(ws.backlinks("wiki", "9").unwrap().len(), 1);
    // Wiki 任务完成后自动完成，不影响 Jira 待办
    let r = ws.sync_wiki_todos(&[]).unwrap();
    assert_eq!(r.completed, 1);
    assert!(!ws.todo(&jira_todo_id("ABC-1")).unwrap().unwrap().done);
}

#[test]
fn published_page_is_remembered() {
    let dir = tempfile::tempdir().unwrap();
    let ws = open(dir.path(), "a.db");
    let doc = ws.save_doc(DocInput { kind: "page".into(), title: "方案".into(), content: "正文".into(), ..Default::default() }).unwrap();
    let url = "https://w/pages/viewpage.action?pageId=5&pageVersion=1";
    ws.set_published(&doc.id, url).unwrap();
    let saved = ws.save_doc(DocInput { id: Some(doc.id.clone()), kind: "page".into(), title: "方案".into(), content: "改过".into(), ..Default::default() }).unwrap();
    assert_eq!(saved.published_url.as_deref(), Some(url), "保存正文时保留发布地址");
    assert_eq!(ws.docs("page").unwrap()[0].published_url.as_deref(), Some(url));
}

#[test]
fn docs_tree_tags_and_daily() {
    let dir = tempfile::tempdir().unwrap();
    let ws = open(dir.path(), "a.db");
    let root = ws.save_doc(DocInput { kind: "page".into(), title: "部署手册".into(), tags: vec!["运维".into(), "#运维".into(), " 发布 ".into()], ..Default::default() }).unwrap();
    assert_eq!(root.tags, ["运维", "发布"]);
    let child = ws.save_doc(DocInput { kind: "page".into(), title: "回滚步骤".into(), parent_id: Some(root.id.clone()), ..Default::default() }).unwrap();
    assert!(ws.move_doc(&root.id, Some(&child.id), 0.0).is_err(), "不能移到自己的下级");
    assert_eq!(ws.tags().unwrap()[0], ("发布".to_string(), 1));

    assert_eq!(ws.delete_doc(&root.id).unwrap(), 2);
    assert!(ws.docs("page").unwrap().is_empty());

    let day = ws.daily("2026-10-22").unwrap();
    assert_eq!(day.id, "daily-2026-10-22");
    assert!(ws.daily_days().unwrap().is_empty(), "空日记不算写过");
    ws.save_doc(DocInput { id: Some(day.id), kind: "daily".into(), title: day.title, content: "今天".into(), ..Default::default() }).unwrap();
    assert_eq!(ws.daily_days().unwrap(), ["2026-10-22"]);
    assert_eq!(ws.doc("daily-2026-10-22").unwrap().unwrap().day.as_deref(), Some("2026-10-22"));
}

#[test]
fn backlinks_and_search() {
    let dir = tempfile::tempdir().unwrap();
    let ws = open(dir.path(), "a.db");
    let page = ws.save_doc(DocInput { kind: "page".into(), title: "库存计算说明".into(), content: "库存为零时金额应为零".into(), ..Default::default() }).unwrap();
    ws.save_doc(note("排查记录", &format!("PROJ-21398 的原因见 [说明](ws://doc/{})", page.id))).unwrap();
    ws.save_todo(TodoInput { title: "跟进".into(), ref_system: Some("jira".into()), ref_key: Some("PROJ-21398".into()), ..Default::default() }).unwrap();

    let links = ws.backlinks("jira", "PROJ-21398").unwrap();
    assert_eq!(links.len(), 2);
    assert_eq!(ws.backlinks("doc", &page.id).unwrap()[0].title, "排查记录");

    // 三个字以上走全文索引，更短的逐条匹配
    let hits = ws.search("金额应为", 10).unwrap();
    assert_eq!(hits[0].title, "库存计算说明");
    assert!(hits[0].snippet.contains("金额应为"));
    assert_eq!(ws.search("库存", 10).unwrap().len(), 1);
    assert_eq!(ws.search("跟进", 10).unwrap()[0].item_type, "todo");
}

#[test]
fn sync_between_two_devices() {
    let dir = tempfile::tempdir().unwrap();
    let shared = dir.path().join("sync");
    let a = open(dir.path(), "a.db");
    let b = open(dir.path(), "b.db");

    let t = a.save_todo(todo("A 的待办")).unwrap();
    let n = a.save_doc(note("会议记录", "第一版")).unwrap();
    let asset = a.save_asset("image/png", b"PNG").unwrap();
    assert_eq!(a.sync(&shared).unwrap().exported, 3);
    let r = b.sync(&shared).unwrap();
    assert_eq!((r.imported, r.devices), (2, 1));
    assert_eq!(b.todos().unwrap()[0].title, "A 的待办");
    assert_eq!(b.asset(&asset.id).unwrap().unwrap().1, b"PNG");

    // B 修改后同步回 A
    b.set_todo_done(&t.id, true).unwrap();
    b.sync(&shared).unwrap();
    a.sync(&shared).unwrap();
    assert!(a.todo(&t.id).unwrap().unwrap().done);
    // 再同步一次不会重复合并
    assert_eq!(a.sync(&shared).unwrap().imported, 0);

    // 两端同时修改同一篇笔记：后改的胜出，另一端的内容保存为冲突副本
    a.save_doc(DocInput { id: Some(n.id.clone()), content: "A 的修改".into(), ..note("会议记录", "") }).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(5));
    b.save_doc(DocInput { id: Some(n.id.clone()), content: "B 的修改".into(), ..note("会议记录", "") }).unwrap();
    b.sync(&shared).unwrap();
    let r = a.sync(&shared).unwrap();
    assert_eq!(r.conflicts, 1);
    assert_eq!(a.doc(&n.id).unwrap().unwrap().content, "B 的修改");
    let notes = a.docs("note").unwrap();
    assert!(notes.iter().any(|d| d.title == "会议记录（冲突副本）" && d.excerpt == "A 的修改"));
    // 冲突副本也会同步到 B
    a.sync(&shared).unwrap();
    b.sync(&shared).unwrap();
    assert_eq!(b.docs("note").unwrap().len(), 2);

    // A 的修改已经导出过、B 还没看到时 B 也改了：A 的修改同样不会丢
    b.sync(&shared).unwrap();
    a.sync(&shared).unwrap();
    a.save_doc(DocInput { id: Some(n.id.clone()), content: "A 的第二次修改".into(), ..note("会议记录", "") }).unwrap();
    a.sync(&shared).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(5));
    b.save_doc(DocInput { id: Some(n.id.clone()), content: "B 的第二次修改".into(), ..note("会议记录", "") }).unwrap();
    b.sync(&shared).unwrap();
    assert_eq!(a.sync(&shared).unwrap().conflicts, 1);
    assert!(a.docs("note").unwrap().iter().any(|d| d.excerpt == "A 的第二次修改"));
    // 顺序修改（B 先看到 A 的版本再改）不算冲突
    b.sync(&shared).unwrap();
    b.save_doc(DocInput { id: Some(n.id.clone()), content: "B 接着改".into(), ..note("会议记录", "") }).unwrap();
    b.sync(&shared).unwrap();
    assert_eq!(a.sync(&shared).unwrap().conflicts, 0);
    assert_eq!(a.doc(&n.id).unwrap().unwrap().content, "B 接着改");

    // 删除同步
    a.delete_todo(&t.id).unwrap();
    a.sync(&shared).unwrap();
    b.sync(&shared).unwrap();
    assert!(b.todos().unwrap().is_empty());
}

#[test]
fn sync_skips_incomplete_lines() {
    let dir = tempfile::tempdir().unwrap();
    let shared = dir.path().join("sync");
    let a = open(dir.path(), "a.db");
    let b = open(dir.path(), "b.db");
    a.save_todo(todo("完整的")).unwrap();
    a.sync(&shared).unwrap();
    // 模拟同步盘只传过来半行
    let file = shared.join("devices").join(format!("{}.jsonl", a.device_id()));
    let mut text = std::fs::read_to_string(&file).unwrap();
    text.push_str("{\"type\":\"todo\",\"row\":{\"id\":\"x");
    std::fs::write(&file, &text).unwrap();
    assert_eq!(b.sync(&shared).unwrap().imported, 1);
    assert_eq!(b.todos().unwrap().len(), 1);
}

#[test]
fn compaction_keeps_latest_versions() {
    let dir = tempfile::tempdir().unwrap();
    let shared = dir.path().join("sync");
    let a = open(dir.path(), "a.db");
    let b = open(dir.path(), "b.db");
    let big = "长".repeat(1024 * 1024);
    let doc = a.save_doc(note("大文档", &big)).unwrap();
    a.sync(&shared).unwrap();
    b.sync(&shared).unwrap();
    // 反复修改让日志超过阈值，触发整理
    for i in 0..4 {
        a.save_doc(DocInput { id: Some(doc.id.clone()), content: format!("{big}{i}"), ..note("大文档", "") }).unwrap();
        a.sync(&shared).unwrap();
    }
    let file = shared.join("devices").join(format!("{}.jsonl", a.device_id()));
    let len = std::fs::metadata(&file).unwrap().len();
    assert!(len < sync::COMPACT_THRESHOLD, "整理后只剩最新版本：{len}");
    // B 从头重读，得到最新内容
    let r = b.sync(&shared).unwrap();
    let got = b.doc(&doc.id).unwrap().unwrap().content;
    assert!(got.ends_with('3'), "imported={} tail={:?} len={len}", r.imported, got.chars().rev().take(2).collect::<String>());
}

#[test]
fn migrates_old_databases() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("old.db");
    {
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch("CREATE TABLE sync_cursors (device TEXT PRIMARY KEY, offset INTEGER NOT NULL);").unwrap();
    }
    let ws = Workspace::open(&path).unwrap();
    ws.save_todo(todo("迁移后可用")).unwrap();
    let shared = dir.path().join("sync");
    ws.sync(&shared).unwrap();
}

#[test]
fn next_occurrence_skips_past_dates() {
    let d = |s: &str| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap();
    let today = d("2026-10-23"); // 星期五
    assert_eq!(next_occurrence(Some("2026-10-23"), "daily", today), Some(d("2026-10-24")));
    assert_eq!(next_occurrence(Some("2026-10-23"), "weekdays", today), Some(d("2026-10-26")));
    // 逾期很久的跳到今天之后
    assert_eq!(next_occurrence(Some("2026-10-01"), "weekly", today), Some(d("2026-10-29")));
    // 提前完成的按截止日期推进
    assert_eq!(next_occurrence(Some("2026-11-05"), "weekly", today), Some(d("2026-11-12")));
    assert_eq!(next_occurrence(Some("2026-01-31"), "monthly", d("2026-01-31")), Some(d("2026-02-28")));
    assert_eq!(next_occurrence(None, "daily", today), Some(d("2026-10-24")));
    assert_eq!(next_occurrence(Some("2026-10-23"), "yearly", today), None);
}

#[test]
fn completing_repeating_todo_creates_next() {
    let dir = tempfile::tempdir().unwrap();
    let ws = open(dir.path(), "a.db");
    let due = chrono::Local::now().date_naive();
    let remind = due.and_hms_opt(9, 30, 0).unwrap().and_local_timezone(chrono::Local).unwrap().timestamp_millis();
    let t = ws
        .save_todo(TodoInput {
            title: "站会".into(),
            due: Some(due.to_string()),
            repeat: Some("daily".into()),
            remind_at: Some(remind),
            checklist: vec![ChecklistItem { id: "1".into(), text: "同步进度".into(), done: true }],
            ..Default::default()
        })
        .unwrap();
    let done = ws.set_todo_done(&t.id, true).unwrap();
    assert!(done.done && done.repeat.is_none());
    let open_todos: Vec<Todo> = ws.todos().unwrap().into_iter().filter(|t| !t.done).collect();
    assert_eq!(open_todos.len(), 1);
    let next = &open_todos[0];
    assert_eq!(next.title, "站会");
    assert_eq!(next.due.as_deref(), Some((due + chrono::Duration::days(1)).to_string().as_str()));
    assert_eq!(next.remind_at, Some(remind + 86_400_000));
    assert_eq!(next.repeat.as_deref(), Some("daily"));
    assert!(!next.checklist[0].done);
    // 取消再勾选已完成的那条不会再生成
    ws.set_todo_done(&t.id, false).unwrap();
    ws.set_todo_done(&t.id, true).unwrap();
    assert_eq!(ws.todos().unwrap().len(), 2);
}

#[test]
fn inbox_state_and_sync() {
    let dir = tempfile::tempdir().unwrap();
    let shared = dir.path().join("sync");
    let a = open(dir.path(), "a.db");
    let b = open(dir.path(), "b.db");
    let c = a.capture("看一下这个链接", "https://example.com/x", Some("https://example.com/x")).unwrap();
    a.set_inbox_state("mr:1:2", "评审 !2", Some(100), None).unwrap();
    a.sync(&shared).unwrap();
    b.sync(&shared).unwrap();
    let entries = b.inbox().unwrap();
    assert_eq!(entries.len(), 2);
    assert!(entries.iter().any(|e| e.id == "mr:1:2" && e.kind == "state" && e.handled_at == Some(100)));
    b.delete_inbox(&c.id).unwrap();
    b.sync(&shared).unwrap();
    a.sync(&shared).unwrap();
    assert_eq!(a.inbox().unwrap().len(), 1);
}

#[test]
fn due_alerts_fire_once() {
    let dir = tempfile::tempdir().unwrap();
    let ws = open(dir.path(), "a.db");
    let now = now_ms();
    let t = ws.save_todo(TodoInput { title: "开会".into(), remind_at: Some(now - 1000), ..Default::default() }).unwrap();
    ws.save_todo(TodoInput { title: "很久以前".into(), remind_at: Some(now - 48 * 3600 * 1000), ..Default::default() }).unwrap();
    ws.save_todo(TodoInput { title: "以后".into(), remind_at: Some(now + 3600 * 1000), ..Default::default() }).unwrap();
    let e = ws.capture("回复邮件", "", None).unwrap();
    ws.set_inbox_state(&e.id, "", None, Some(now - 10)).unwrap();
    let alerts = ws.take_due_alerts(now).unwrap();
    let titles: Vec<&str> = alerts.iter().map(|a| a.title.as_str()).collect();
    assert_eq!(titles.len(), 2);
    assert!(titles.contains(&"开会") && titles.contains(&"回复邮件"));
    assert!(ws.take_due_alerts(now).unwrap().is_empty());
    // 改了提醒时间会再次提醒
    ws.save_todo(TodoInput { id: Some(t.id.clone()), title: "开会".into(), remind_at: Some(now - 500), ..Default::default() }).unwrap();
    assert_eq!(ws.take_due_alerts(now).unwrap().len(), 1);
}

#[test]
fn time_entries_by_range() {
    let dir = tempfile::tempdir().unwrap();
    let ws = open(dir.path(), "a.db");
    let entry = |id: &str, start: i64, end: i64| TimeEntry { id: id.into(), title: id.into(), issue_key: None, todo_id: None, started_at: start, ended_at: end, duration_ms: end - start };
    ws.add_time_entry(&entry("a", 100, 200)).unwrap();
    ws.add_time_entry(&entry("b", 300, 400)).unwrap();
    let got: Vec<String> = ws.time_entries(150, 350).unwrap().into_iter().map(|e| e.id).collect();
    assert_eq!(got, ["a", "b"]);
    assert!(ws.time_entries(200, 300).unwrap().is_empty());
}
