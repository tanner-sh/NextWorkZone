use super::*;

fn store() -> (tempfile::TempDir, Store) {
    let dir = tempfile::tempdir().unwrap();
    let store = Store::open(dir.path()).unwrap();
    (dir, store)
}

fn text(value: &str) -> Capture {
    Capture { text: Some(value.into()), app: Some(("com.example.editor".into(), "编辑器".into())), ..Default::default() }
}

#[test]
fn dedups_and_moves_to_front() {
    let (_dir, store) = store();
    let (first, new) = store.add(text("第一条")).unwrap().unwrap();
    assert!(new);
    store.add(text("https://example.com")).unwrap();
    let (again, new) = store.add(text("第一条")).unwrap().unwrap();
    assert!(!new);
    assert_eq!(again.id, first.id);
    assert_eq!(again.copy_count, 2);
    let list = store.list(&ListQuery::default()).unwrap();
    assert_eq!(list.iter().map(|i| i.id.as_str()).collect::<Vec<_>>()[0], first.id);
    assert_eq!(list[1].kind, classify::LINK);
    assert!(store.add(Capture { text: Some("  ".into()), ..Default::default() }).unwrap().is_none());
}

#[test]
fn searches_and_filters() {
    let (_dir, store) = store();
    store.add(text("修复导出失败的问题 PROJ-123")).unwrap();
    store.add(text("#ff8800")).unwrap();
    store.add(Capture { text: Some("from another app".into()), app: Some(("com.example.chat".into(), "聊天".into())), ..Default::default() }).unwrap();
    let find = |query: ListQuery| store.list(&query).unwrap().into_iter().map(|i| i.text).collect::<Vec<_>>();
    assert_eq!(find(ListQuery { text: "导出失败".into(), ..Default::default() }), ["修复导出失败的问题 PROJ-123"]);
    // 少于 3 个字符时用 LIKE 搜索
    assert_eq!(find(ListQuery { text: "导出".into(), ..Default::default() }).len(), 1);
    assert_eq!(find(ListQuery { text: "聊天".into(), ..Default::default() }), ["from another app"]);
    assert_eq!(find(ListQuery { kind: Some("color".into()), ..Default::default() }), ["#ff8800"]);
    assert_eq!(find(ListQuery { app: Some("com.example.chat".into()), ..Default::default() }).len(), 1);
    assert_eq!(find(ListQuery { text: "100%".into(), ..Default::default() }).len(), 0);
}

#[test]
fn pinboards_survive_pruning() {
    let (_dir, store) = store();
    let (a, _) = store.add(text("a")).unwrap().unwrap();
    let (b, _) = store.add(text("b")).unwrap().unwrap();
    let (c, _) = store.add(text("c")).unwrap().unwrap();
    let board = store.save_pinboard(None, "常用", "#3b82f6").unwrap();
    store.set_pinboard(std::slice::from_ref(&a.id), Some(&board.id)).unwrap();
    assert_eq!(store.pinboards().unwrap()[0].count, 1);
    // 只保留 1 条未置顶的：b 被清理，c 最新保留，a 已置顶
    assert_eq!(store.prune(0, 1).unwrap(), 1);
    let ids: Vec<_> = store.list(&ListQuery::default()).unwrap().into_iter().map(|i| i.id).collect();
    assert!(ids.contains(&a.id) && ids.contains(&c.id) && !ids.contains(&b.id));
    let pinned = store.list(&ListQuery { pinboard: Some(board.id.clone()), ..Default::default() }).unwrap();
    assert_eq!(pinned.len(), 1);
    store.delete_pinboard(&board.id).unwrap();
    assert!(store.item(&a.id).unwrap().unwrap().pinboard.is_none());
    assert_eq!(store.clear_history().unwrap(), 2);
}

#[test]
fn stores_images_and_files() {
    let (_dir, store) = store();
    let rgba = [255u8, 0, 0, 255].repeat(600 * 300);
    let (image, _) = store.add(Capture { image: Some((600, 300, rgba.clone())), ..Default::default() }).unwrap().unwrap();
    assert_eq!(image.kind, classify::IMAGE);
    assert_eq!(image.image.as_ref().unwrap().width, 600);
    assert!(store.image_path(&image.id).exists());
    let thumb = ::image::open(store.thumb_path(&image.id)).unwrap();
    assert_eq!((thumb.width(), thumb.height()), (480, 240));
    // 同样的像素不重复保存
    assert!(!store.add(Capture { image: Some((600, 300, rgba)), ..Default::default() }).unwrap().unwrap().1);

    let (files, _) = store.add(Capture { files: vec!["/tmp/a.txt".into(), "/tmp/b.png".into()], ..Default::default() }).unwrap().unwrap();
    assert_eq!(files.kind, classify::FILE);
    assert_eq!(files.files.len(), 2);
    assert_eq!(store.list(&ListQuery { text: "b.png".into(), ..Default::default() }).unwrap().len(), 1);

    store.delete(std::slice::from_ref(&image.id)).unwrap();
    assert!(!store.image_path(&image.id).exists());
}

#[test]
fn edits_and_renames() {
    let (_dir, store) = store();
    let (a, _) = store.add(text("旧内容")).unwrap().unwrap();
    let (b, _) = store.add(text("另一条")).unwrap().unwrap();
    let edited = store.update_text(&a.id, "{\"a\": 1}").unwrap().unwrap();
    assert_eq!(edited.kind, classify::CODE);
    // 改成与另一条相同的内容时合并
    let merged = store.update_text(&a.id, "另一条").unwrap().unwrap();
    assert_eq!(merged.id, b.id);
    assert!(store.item(&a.id).unwrap().is_none());
    store.rename(&b.id, "签名").unwrap();
    assert_eq!(store.list(&ListQuery { text: "签名".into(), ..Default::default() }).unwrap().len(), 1);
}

#[test]
fn picks_icon_color() {
    let mut icon = ::image::RgbaImage::new(8, 8);
    for (x, _, p) in icon.enumerate_pixels_mut() {
        p.0 = if x < 6 { [40, 120, 240, 255] } else { [255, 255, 255, 255] };
    }
    assert_eq!(dominant_color(&icon).as_deref(), Some("#2878f0"));
    let gray = ::image::RgbaImage::from_pixel(8, 8, ::image::Rgba([128, 128, 128, 255]));
    assert_eq!(dominant_color(&gray), None);
}
