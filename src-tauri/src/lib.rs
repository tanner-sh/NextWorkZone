mod asset;
mod capture;
mod clipboard;
mod commands;
mod devbridge;
mod shortcuts;
mod state;
mod tray;

use commands::{activity, gitlab, inbox, jira, jira_index, jira_tools, search, session, settings, tools, weekly, wiki, worklog, workspace};
use nextworkzone_core::secrets::Store;
use tauri::Manager;

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .plugin(tauri_plugin_global_shortcut::Builder::new().build())
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
            tauri::async_runtime::spawn(inbox::alert_loop(app.handle().clone()));
            tray::setup(app.handle())?;
            capture::setup(app.handle())?;
            clipboard::setup(app.handle())?;
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
            jira::local_image_preview,
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
            workspace::ws_save_capture_shortcut,
            inbox::ws_inbox,
            inbox::ws_inbox_handle,
            inbox::ws_inbox_snooze,
            worklog::ws_worklog,
            capture::capture_hide,
            capture::capture_clipboard,
            capture::clipboard_read_text,
            tools::tools_hidden,
            tools::tools_set_hidden,
            clipboard::clip_paste,
            clipboard::clip_copy,
            clipboard::clip_hide,
            clipboard::clip_open_main,
            clipboard::clip_list,
            clipboard::clip_text,
            clipboard::clip_delete,
            clipboard::clip_clear,
            clipboard::clip_set_pinboard,
            clipboard::clip_rename,
            clipboard::clip_update_text,
            clipboard::clip_pinboards,
            clipboard::clip_save_pinboard,
            clipboard::clip_delete_pinboard,
            clipboard::clip_order_pinboards,
            clipboard::clip_apps,
            clipboard::clip_issues,
            clipboard::clip_settings,
            clipboard::clip_save_settings,
            clipboard::clip_pause,
            clipboard::clip_request_permission,
            clipboard::clip_ignore_candidates,
            clipboard::clip_touch,
            clipboard::clip_drag,
        ])
        // 关闭主窗口只是隐藏，应用继续在后台同步、提醒；从托盘或程序坞图标重新打开，⌘Q 或托盘菜单“退出”才退出
        .on_window_event(|window, event| match (window.label(), event) {
            ("main", tauri::WindowEvent::CloseRequested { api, .. }) => {
                api.prevent_close();
                let _ = window.hide();
            }
            // 快速记录窗口：关闭只是隐藏；切到别的应用时自动收起
            (capture::CAPTURE_LABEL, tauri::WindowEvent::CloseRequested { api, .. }) => {
                api.prevent_close();
                capture::hide(window.app_handle());
            }
            (capture::CAPTURE_LABEL, tauri::WindowEvent::Focused(false)) => {
                let _ = window.hide();
            }
            // 剪贴板面板：同上，切到别的应用时收起
            (clipboard::PANEL_LABEL, tauri::WindowEvent::CloseRequested { api, .. }) => {
                api.prevent_close();
                clipboard::hide(window.app_handle(), false);
            }
            (clipboard::PANEL_LABEL, tauri::WindowEvent::Focused(false)) => {
                let _ = window.hide();
            }
            _ => {}
        })
        .build(tauri::generate_context!())
        .expect("启动 NextWorkZone 失败")
        .run(|app, event| {
            #[cfg(target_os = "macos")]
            if let tauri::RunEvent::Reopen { .. } = event {
                tray::show_main(app);
            }
            #[cfg(not(target_os = "macos"))]
            let _ = (app, event);
        });
}
