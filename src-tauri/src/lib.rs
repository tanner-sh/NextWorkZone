mod asset;
mod commands;
mod devbridge;
mod state;

use commands::{activity, gitlab, jira, jira_index, jira_tools, search, session, settings, weekly, wiki, workspace};
use nextworkzone_core::secrets::Store;
use tauri::Manager;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .register_asynchronous_uri_scheme_protocol("nextworkzone", asset::handle)
        .setup(|app| {
            let config_dir = app.path().app_config_dir()?;
            let data_dir = app.path().app_data_dir()?;
            let cache_dir = app.path().app_cache_dir()?;
            // 开发版每次编译签名都会变，钥匙串会反复要求授权，因此改用本地私有文件
            let store = if cfg!(debug_assertions) {
                Store::File(config_dir.join("dev-credentials.json"))
            } else {
                Store::Keychain
            };
            app.manage(state::AppState::load(config_dir.join("config.json"), cache_dir, data_dir, store)?);
            tauri::async_runtime::spawn(session::keep_alive_loop(app.handle().clone()));
            tauri::async_runtime::spawn(workspace::sync_loop(app.handle().clone()));
            tauri::async_runtime::spawn(jira_index::sync_loop(app.handle().clone()));
            tauri::async_runtime::spawn(wiki::sync_loop(app.handle().clone()));
            // 本机测试通道只在开发构建中启动
            if cfg!(debug_assertions) {
                devbridge::start(app.handle());
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            settings::get_settings,
            settings::save_settings,
            settings::clear_token,
            settings::import_tokens_env,
            settings::test_connection,
            jira::jira_cached_search,
            jira::jira_search,
            jira::jira_fields,
            jira::jira_my_worklogs,
            jira::jira_issue,
            jira::jira_transitions,
            jira::jira_transition,
            jira::jira_add_comment,
            jira::jira_update_comment,
            jira::jira_comment_levels,
            jira::jira_delete_comment,
            jira::jira_me,
            jira::jira_assign,
            jira::jira_watchers,
            jira::jira_set_watching,
            jira::jira_priorities,
            jira::jira_set_priority,
            jira::jira_favourite_filters,
            jira_index::jira_similar_issues,
            jira_index::jira_index_status,
            jira_index::jira_index_sync,
            jira_index::jira_index_rebuild,
            jira_index::jira_index_search,
            jira_index::jira_viewed,
            jira_index::jira_mark_viewed,
            jira_tools::jira_tools_settings,
            jira_tools::jira_save_tools_settings,
            jira_tools::jira_reminders,
            activity::jira_activity,
            activity::jira_activity_poll,
            activity::jira_activity_read,
            jira::jira_upload_attachments,
            jira::jira_open_attachment,
            jira::jira_preview_attachment,
            jira::jira_edit_fields,
            jira::jira_update_issue,
            jira::jira_cached_create_projects,
            jira::jira_create_projects,
            jira::jira_create_fields,
            jira::jira_create_issue,
            jira::jira_find_users,
            jira::jira_suggested_assignees,
            jira::jira_suggest_labels,
            jira::jira_search_epics,
            jira::jira_pick_issues,
            jira::jira_link_types,
            jira::jira_add_link,
            jira::jira_delete_link,
            jira::jira_worklogs,
            jira::jira_save_worklog,
            jira::jira_delete_worklog,
            jira::jira_history,
            jira::jira_render_wiki,
            jira::jira_save_pasted_image,
            weekly::weekly_load,
            weekly::weekly_save,
            weekly::weekly_create_week,
            weekly::weekly_draft,
            wiki::wiki_cached_spaces,
            wiki::wiki_spaces,
            wiki::wiki_space_roots,
            wiki::wiki_children,
            wiki::wiki_page,
            wiki::wiki_resolve,
            wiki::wiki_attachments,
            wiki::wiki_recent,
            wiki::wiki_versions,
            wiki::wiki_diff,
            wiki::wiki_version_html,
            wiki::wiki_page_version,
            wiki::wiki_comments,
            wiki::wiki_add_comment,
            wiki::wiki_set_task,
            wiki::wiki_users,
            wiki::wiki_search,
            wiki::wiki_issue_pages,
            wiki::wiki_edit,
            wiki::wiki_new_page,
            wiki::wiki_templates,
            wiki::wiki_preview_save,
            wiki::wiki_save,
            wiki::wiki_create,
            wiki::wiki_index_status,
            wiki::wiki_index_sync,
            wiki::wiki_index_rebuild,
            wiki::wiki_tools_settings,
            wiki::wiki_save_tools_settings,
            gitlab::gl_cached_projects,
            gitlab::gl_projects,
            gitlab::gl_project,
            gitlab::gl_branches,
            gitlab::gl_tree,
            gitlab::gl_file,
            gitlab::gl_commits,
            gitlab::gl_commit,
            gitlab::gl_compare,
            gitlab::gl_me,
            gitlab::gl_merge_requests,
            gitlab::gl_project_merge_requests,
            gitlab::gl_merge_request,
            gitlab::gl_mr_changes,
            gitlab::gl_mr_commits,
            gitlab::gl_mr_discussions,
            gitlab::gl_mr_approvals,
            gitlab::gl_mr_add_note,
            gitlab::gl_mr_reply,
            gitlab::gl_mr_edit_note,
            gitlab::gl_mr_delete_note,
            gitlab::gl_mr_resolve,
            gitlab::gl_mr_approve,
            gitlab::gl_mr_merge,
            gitlab::gl_mr_update,
            gitlab::gl_mr_create,
            search::global_search,
            session::web_access_status,
            session::web_login,
            session::web_logout,
            workspace::ws_todos,
            workspace::ws_save_todo,
            workspace::ws_set_todo_done,
            workspace::ws_move_todo,
            workspace::ws_delete_todo,
            workspace::ws_refresh_jira_todos,
            workspace::ws_docs,
            workspace::ws_doc,
            workspace::ws_full_docs,
            workspace::ws_daily,
            workspace::ws_daily_days,
            workspace::ws_save_doc,
            workspace::ws_move_doc,
            workspace::ws_delete_doc,
            workspace::ws_tags,
            workspace::ws_backlinks,
            workspace::ws_search,
            workspace::ws_save_asset,
            workspace::ws_settings,
            workspace::ws_save_settings,
            workspace::ws_sync,
            workspace::ws_wiki_page,
            workspace::ws_publish_to_wiki,
            devbridge::dev_eval_result,
        ])
        .run(tauri::generate_context!())
        .expect("启动 NextWorkZone 失败");
}
