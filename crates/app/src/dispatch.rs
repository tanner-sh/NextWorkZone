//! 统一的命令入口：各端界面按名称调用命令，参数和结果都是 JSON（参数名为 camelCase）。
//!
//! Tauri 前端和 macOS 原生界面调用的是同一组命令，新增命令只需要在这里登记一次。

use std::sync::Arc;

use nextworkzone_core::{Error, Result};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::Value;

use crate::clipboard;
use crate::commands::*;
use crate::state::AppState;

/// 取出参数；没有传的参数按 `null` 处理（对应 `Option` 为 `None`）。
fn arg<T: DeserializeOwned>(args: &Value, name: &str) -> Result<T> {
    let value = args.get(name).cloned().unwrap_or(Value::Null);
    serde_json::from_value(value).map_err(|e| Error::Other(format!("参数 {name} 格式不正确：{e}")))
}

fn json(value: impl Serialize) -> Result<Value> {
    Ok(serde_json::to_value(value)?)
}

/// 执行命令 `cmd`。
pub async fn dispatch(state: &Arc<AppState>, cmd: &str, args: Value) -> Result<Value> {
    match cmd {
        "weekly_load" => json(weekly::weekly_load(state, arg(&args, "section")?).await?),
        "weekly_save" => json(weekly::weekly_save(state, arg(&args, "input")?).await?),
        "weekly_create_week" => json(weekly::weekly_create_week(state).await?),
        "weekly_draft" => json(weekly::weekly_draft(state, arg(&args, "section")?).await?),
        "wiki_cached_spaces" => json(wiki::wiki_cached_spaces(state).await?),
        "wiki_spaces" => json(wiki::wiki_spaces(state).await?),
        "wiki_space_roots" => json(wiki::wiki_space_roots(state, arg(&args, "space")?).await?),
        "wiki_children" => json(wiki::wiki_children(state, arg(&args, "page")?).await?),
        "wiki_page" => json(wiki::wiki_page(state, arg(&args, "page")?).await?),
        "wiki_resolve" => json(wiki::wiki_resolve(state, arg(&args, "input")?).await?),
        "wiki_attachments" => json(wiki::wiki_attachments(state, arg(&args, "page")?).await?),
        "wiki_recent" => json(wiki::wiki_recent(state, arg(&args, "limit")?).await?),
        "wiki_versions" => json(wiki::wiki_versions(state, arg(&args, "page")?).await?),
        "wiki_diff" => json(wiki::wiki_diff(state, arg(&args, "page")?, arg(&args, "from")?, arg(&args, "to")?).await?),
        "wiki_version_html" => json(wiki::wiki_version_html(state, arg(&args, "page")?, arg(&args, "version")?).await?),
        "wiki_page_version" => json(wiki::wiki_page_version(state, arg(&args, "page")?).await?),
        "wiki_comments" => json(wiki::wiki_comments(state, arg(&args, "page")?).await?),
        "wiki_add_comment" => json(wiki::wiki_add_comment(state, arg(&args, "page")?, arg(&args, "parent")?, arg(&args, "text")?).await?),
        "wiki_set_task" => json(wiki::wiki_set_task(state, arg(&args, "page")?, arg(&args, "task")?, arg(&args, "done")?).await?),
        "wiki_users" => json(wiki::wiki_users(state, arg(&args, "keys")?).await?),
        "wiki_search" => json(wiki::wiki_search(state, arg(&args, "query")?, arg(&args, "server")?, arg(&args, "start")?).await?),
        "wiki_issue_pages" => json(wiki::wiki_issue_pages(state, arg(&args, "key")?).await?),
        "issue_code_refs" => json(code_refs::issue_code_refs(state, arg(&args, "key")?, arg(&args, "texts")?).await?),
        "code_related_issues" => json(code_refs::code_related_issues(state, arg(&args, "target")?).await?),
        "wiki_edit" => json(wiki::wiki_edit(state, arg(&args, "page")?).await?),
        "wiki_new_page" => json(wiki::wiki_new_page(state, arg(&args, "space")?, arg(&args, "template")?, arg(&args, "storage")?).await?),
        "wiki_templates" => json(wiki::wiki_templates(state, arg(&args, "space")?).await?),
        "wiki_preview_save" => json(wiki::wiki_preview_save(state, arg(&args, "page")?, arg(&args, "xhtml")?, arg(&args, "fragments")?).await?),
        "wiki_save" => json(wiki::wiki_save(state, arg(&args, "page")?, arg(&args, "title")?, arg(&args, "xhtml")?, arg(&args, "fragments")?, arg(&args, "baseVersion")?, arg(&args, "minorEdit")?, arg(&args, "message")?).await?),
        "wiki_create" => json(wiki::wiki_create(state, arg(&args, "space")?, arg(&args, "parent")?, arg(&args, "title")?, arg(&args, "xhtml")?, arg(&args, "fragments")?).await?),
        "wiki_index_status" => json(wiki::wiki_index_status(state).await?),
        "wiki_index_sync" => {
            let _: () = wiki::wiki_index_sync().await;
            json(())
        },
        "wiki_index_rebuild" => json(wiki::wiki_index_rebuild(state).await?),
        "wiki_tools_settings" => json(wiki::wiki_tools_settings(state).await),
        "wiki_save_tools_settings" => json(wiki::wiki_save_tools_settings(state, arg(&args, "settings")?).await?),
        "gl_cached_projects" => json(gitlab::gl_cached_projects(state).await?),
        "gl_projects" => json(gitlab::gl_projects(state, arg(&args, "search")?).await?),
        "gl_project" => json(gitlab::gl_project(state, arg(&args, "id")?).await?),
        "gl_branches" => json(gitlab::gl_branches(state, arg(&args, "project")?).await?),
        "gl_tree" => json(gitlab::gl_tree(state, arg(&args, "project")?, arg(&args, "gitRef")?, arg(&args, "path")?).await?),
        "gl_file" => json(gitlab::gl_file(state, arg(&args, "project")?, arg(&args, "gitRef")?, arg(&args, "path")?).await?),
        "gl_commits" => json(gitlab::gl_commits(state, arg(&args, "project")?, arg(&args, "gitRef")?, arg(&args, "path")?, arg(&args, "page")?).await?),
        "gl_commit" => json(gitlab::gl_commit(state, arg(&args, "project")?, arg(&args, "sha")?).await?),
        "gl_compare" => json(gitlab::gl_compare(state, arg(&args, "project")?, arg(&args, "from")?, arg(&args, "to")?).await?),
        "gl_me" => json(gitlab::gl_me(state).await?),
        "gl_merge_requests" => json(gitlab::gl_merge_requests(state, arg(&args, "scope")?, arg(&args, "query")?).await?),
        "gl_project_merge_requests" => json(gitlab::gl_project_merge_requests(state, arg(&args, "project")?, arg(&args, "query")?).await?),
        "gl_merge_request" => json(gitlab::gl_merge_request(state, arg(&args, "project")?, arg(&args, "iid")?).await?),
        "gl_mr_changes" => json(gitlab::gl_mr_changes(state, arg(&args, "project")?, arg(&args, "iid")?).await?),
        "gl_mr_commits" => json(gitlab::gl_mr_commits(state, arg(&args, "project")?, arg(&args, "iid")?).await?),
        "gl_mr_discussions" => json(gitlab::gl_mr_discussions(state, arg(&args, "project")?, arg(&args, "iid")?).await?),
        "gl_mr_approvals" => json(gitlab::gl_mr_approvals(state, arg(&args, "project")?, arg(&args, "iid")?).await?),
        "gl_mr_add_note" => json(gitlab::gl_mr_add_note(state, arg(&args, "project")?, arg(&args, "iid")?, arg(&args, "body")?, arg(&args, "position")?).await?),
        "gl_mr_reply" => json(gitlab::gl_mr_reply(state, arg(&args, "project")?, arg(&args, "iid")?, arg(&args, "discussion")?, arg(&args, "body")?).await?),
        "gl_mr_edit_note" => json(gitlab::gl_mr_edit_note(state, arg(&args, "project")?, arg(&args, "iid")?, arg(&args, "note")?, arg(&args, "body")?).await?),
        "gl_mr_delete_note" => json(gitlab::gl_mr_delete_note(state, arg(&args, "project")?, arg(&args, "iid")?, arg(&args, "note")?).await?),
        "gl_mr_resolve" => json(gitlab::gl_mr_resolve(state, arg(&args, "project")?, arg(&args, "iid")?, arg(&args, "discussion")?, arg(&args, "resolved")?).await?),
        "gl_mr_approve" => json(gitlab::gl_mr_approve(state, arg(&args, "project")?, arg(&args, "iid")?, arg(&args, "approve")?).await?),
        "gl_mr_merge" => json(gitlab::gl_mr_merge(state, arg(&args, "project")?, arg(&args, "iid")?, arg(&args, "options")?).await?),
        "gl_mr_update" => json(gitlab::gl_mr_update(state, arg(&args, "project")?, arg(&args, "iid")?, arg(&args, "update")?).await?),
        "gl_mr_create" => json(gitlab::gl_mr_create(state, arg(&args, "project")?, arg(&args, "mr")?).await?),
        "global_search" => json(search::global_search(state, arg(&args, "query")?, arg(&args, "options")?).await?),
        "web_access_status" => json(session::web_access_status(state).await?),
        "web_login_info" => json(session::web_login_info(state, arg(&args, "service")?).await?),
        "web_login_finish" => json(session::web_login_finish(state, arg(&args, "service")?, arg(&args, "url")?, arg(&args, "cookie")?).await?),
        "web_logout" => json(session::web_logout(state, arg(&args, "service")?).await?),
        "bridge_wiki_activity" => json(activity::bridge_wiki_activity(state, arg(&args, "since")?, arg(&args, "first")?).await?),
        "bridge_inbox_sources" => json(inbox::bridge_inbox_sources(state).await?),
        "bridge_work_events" => json(worklog::bridge_work_events(state, arg(&args, "day")?).await?),
        "ws_wiki_page" => json(workspace::ws_wiki_page(state, arg(&args, "page")?).await?),
        "ws_publish_to_wiki" => json(workspace::ws_publish_to_wiki(state, arg(&args, "docId")?, arg(&args, "mode")?, arg(&args, "parent")?, arg(&args, "title")?, arg(&args, "storage")?, arg(&args, "assets")?).await?),
        "clip_paste" => json(clipboard::clip_paste(state, arg(&args, "ids")?, arg(&args, "plain")?, arg(&args, "edited")?).await?),
        "clip_copy" => json(clipboard::clip_copy(state, arg(&args, "ids")?, arg(&args, "plain")?, arg(&args, "edited")?).await?),
        "clip_list" => json(clipboard::clip_list(state, arg(&args, "query")?).await?),
        "clip_text" => json(clipboard::clip_text(state, arg(&args, "id")?).await?),
        "clip_delete" => json(clipboard::clip_delete(state, arg(&args, "ids")?).await?),
        "clip_clear" => json(clipboard::clip_clear(state).await?),
        "clip_set_pinboard" => json(clipboard::clip_set_pinboard(state, arg(&args, "ids")?, arg(&args, "pinboard")?).await?),
        "clip_rename" => json(clipboard::clip_rename(state, arg(&args, "id")?, arg(&args, "title")?).await?),
        "clip_update_text" => json(clipboard::clip_update_text(state, arg(&args, "id")?, arg(&args, "text")?).await?),
        "clip_pinboards" => json(clipboard::clip_pinboards(state).await?),
        "clip_save_pinboard" => json(clipboard::clip_save_pinboard(state, arg(&args, "id")?, arg(&args, "name")?, arg(&args, "color")?).await?),
        "clip_delete_pinboard" => json(clipboard::clip_delete_pinboard(state, arg(&args, "id")?).await?),
        "clip_order_pinboards" => json(clipboard::clip_order_pinboards(state, arg(&args, "ids")?).await?),
        "clip_apps" => json(clipboard::clip_apps(state).await?),
        "clip_issues" => json(clipboard::clip_issues(state, arg(&args, "keys")?).await?),
        "clip_settings" => json(clipboard::clip_settings(state).await?),
        "clip_save_settings" => json(clipboard::clip_save_settings(state, arg(&args, "config")?).await?),
        "clip_pause" => json(clipboard::clip_pause(state, arg(&args, "minutes")?).await?),
        "clip_request_permission" => {
            let _: () = clipboard::clip_request_permission().await;
            json(())
        },
        "clip_ignore_candidates" => json(clipboard::clip_ignore_candidates(state).await?),
        "clip_touch" => json(clipboard::clip_touch(state, arg(&args, "ids")?).await?),
        _ => Err(Error::Other(format!("未知的命令：{cmd}"))),
    }
}
