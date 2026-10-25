/// 调试通道使用显式白名单，新增命令不会自动获得调用权限。
public enum ReadOnlyCommands {
    public static let names: Set<String> = Set("""
        get_settings test_connection
        jira_cached_search jira_search jira_fields jira_my_worklogs jira_issue jira_transitions
        jira_comment_levels jira_me jira_watchers jira_priorities jira_favourite_filters
        jira_similar_issues jira_index_status jira_index_search jira_viewed jira_tools_settings
        jira_reminders jira_activity jira_preview_attachment jira_edit_fields
        jira_cached_create_projects jira_create_projects jira_create_fields jira_find_users
        jira_suggested_assignees jira_suggest_labels jira_search_epics jira_pick_issues
        jira_link_types jira_worklogs jira_history local_image_preview
        weekly_load weekly_draft
        wiki_cached_spaces wiki_spaces wiki_space_roots wiki_children wiki_page wiki_resolve
        wiki_attachments wiki_recent wiki_versions wiki_diff wiki_version_html wiki_page_version
        wiki_comments wiki_users wiki_search wiki_issue_pages wiki_edit wiki_templates
        wiki_preview_save wiki_index_status wiki_tools_settings
        issue_code_refs code_related_issues
        gl_cached_projects gl_projects gl_project gl_branches gl_tree gl_file gl_commits
        gl_commit gl_compare gl_me gl_merge_requests gl_project_merge_requests gl_merge_request
        gl_mr_changes gl_mr_commits gl_mr_discussions gl_mr_approvals
        global_search web_access_status
        ws_todos ws_docs ws_doc ws_full_docs ws_daily_days ws_tags ws_backlinks ws_search
        ws_settings ws_inbox ws_worklog tools_hidden
        clip_list clip_text clip_pinboards clip_apps clip_issues clip_settings clip_ignore_candidates
        rich_from_html rich_from_markdown rich_to_markdown rich_to_wiki rich_to_xhtml
        rich_edit_load rich_edit_xhtml rich_html_to_markdown rich_markdown_to_storage
        """.split(whereSeparator: \.isWhitespace).map(String.init))
}
