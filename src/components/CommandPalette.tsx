import { useEffect, useMemo, useRef, useState } from "react";
import { api, errorMessage } from "../api";
import { useNav, type PageId } from "../state/nav";
import { BookOpen, CalendarDays, CheckSquare, CircleDot, ClipboardList, CornerDownLeft, FileText, FolderGit2, GitPullRequest, ListFilter, Loader2, NotepadText, Plus, Search, Square, type LucideIcon } from "lucide-react";
import { Highlight, useUnifiedSearch } from "../lib/search";
import { toast } from "./Toast";
import { backlinkTarget } from "../pages/workspace/Backlinks";
import { StatusPill } from "./common";
import { openLink, routeUrl } from "../lib/links";
import { useSettings } from "../state/settings";
import { TOOLS } from "../tools/registry";

interface Item {
  id: string;
  icon: LucideIcon;
  group: string;
  title: string;
  subtitle?: string;
  extra?: React.ReactNode;
  run: () => void;
}

const PAGES: { page: PageId; label: string; keywords: string }[] = [
  { page: "home", label: "今天", keywords: "home 首页 今天 概览 需要处理 收件箱 inbox jt" },
  { page: "todos", label: "待办", keywords: "todo 待办 任务 db" },
  { page: "notes", label: "笔记", keywords: "notes 笔记 日记 bj rj" },
  { page: "kb", label: "知识库", keywords: "kb wiki 知识库 文档 zsk" },
  { page: "jira", label: "Jira", keywords: "jira issue 问题 我的问题 wt" },
  { page: "activity", label: "动态", keywords: "activity 动态 通知 提醒 dt tz" },
  { page: "weekly", label: "周报", keywords: "weekly wiki 周报 zb" },
  { page: "wiki", label: "Wiki", keywords: "wiki confluence 文档 页面 空间 wd" },
  { page: "gitlab", label: "GitLab", keywords: "gitlab code 代码 项目 合并请求 dm" },
  { page: "stats", label: "统计", keywords: "stats 统计 报表 tj" },
  { page: "settings", label: "设置", keywords: "settings 设置 sz" },
];

export const HIT_ICONS = { todo: CheckSquare, note: NotepadText, daily: CalendarDays, page: BookOpen } as const;
export const HIT_GROUPS = { todo: "待办", note: "笔记", daily: "日记", page: "知识库" } as const;
export const MR_STATES: Record<string, string> = { opened: "打开", merged: "已合并", closed: "已关闭", locked: "已锁定" };

/** 剪贴板条目的一行摘要。 */
export function clipLine(text: string, title: string): string {
  return title || text.split("\n").find((l) => l.trim() !== "")?.trim() || text.trim();
}

/** 复制剪贴板历史中的条目。 */
export function copyClip(id: string) {
  api.clipCopy([id]).then(
    () => toast("已复制"),
    (e) => toast(errorMessage(e), true),
  );
}

/** Ctrl+K 全局搜索：页面跳转、新建待办，同时搜索工作空间和 Jira、GitLab、Wiki。 */
export function CommandPalette({ onClose, onQuickTodo }: { onClose: () => void; onQuickTodo: () => void }) {
  const { navigate } = useNav();
  const { baseUrl, isReady } = useSettings();
  const [query, setQuery] = useState("");
  // 先显示本机结果（工作空间、本机问题库和 Wiki 库、剪贴板），再补上服务器结果
  const { results, pending: searching, error } = useUnifiedSearch(query, 8);
  const [active, setActive] = useState(0);
  const listRef = useRef<HTMLUListElement>(null);
  const searchable = query.trim().length >= 2 && !/^https?:\/\//.test(query.trim());
  const openSearchPage = () => {
    navigate({ page: "search", searchQuery: query.trim() });
    onClose();
  };

  const items = useMemo<Item[]>(() => {
    const q = query.trim().toLowerCase();
    const go = (fn: () => void) => () => {
      fn();
      onClose();
    };
    const list: Item[] = PAGES.filter((p) => !q || p.label.includes(q) || p.keywords.includes(q)).map((p) => ({
      id: `page-${p.page}`,
      icon: CornerDownLeft,
      group: "跳转",
      title: p.label,
      run: go(() => navigate({ page: p.page })),
    }));
    for (const tool of TOOLS) {
      if (q && !tool.name.includes(q) && !tool.keywords.includes(q)) continue;
      list.push({ id: `tool-${tool.id}`, icon: tool.icon, group: "工具", title: tool.name, subtitle: tool.description, run: go(() => navigate({ page: "tools", tool: tool.id })) });
    }
    // 粘贴的 Jira、Wiki、GitLab 地址：直接在应用内打开
    if (/^https?:\/\//.test(query.trim())) {
      const url = query.trim();
      const route = routeUrl(url, baseUrl);
      if (route) {
        list.unshift({
          id: "open-url",
          icon: CornerDownLeft,
          group: "打开链接",
          title: route === "wiki" || route.page === "wiki" ? "在应用内打开 Wiki 页面" : route.page === "jira" ? `打开问题 ${route.issueKey}` : route.mrIid ? `打开合并请求 ${route.projectPath ?? ""}!${route.mrIid}` : `打开项目 ${route.projectPath ?? ""}`,
          subtitle: url,
          run: go(() => void openLink(url, baseUrl, navigate)),
        });
      }
    }
    if (!q || "新建待办 xjdb todo".includes(q)) {
      list.push({ id: "action-todo", icon: Plus, group: "操作", title: "新建待办", subtitle: "Ctrl+Shift+N", run: go(onQuickTodo) });
    }
    if (q.length >= 2 && !/^https?:\/\//.test(q)) {
      list.push({ id: "search-page", icon: ListFilter, group: "搜索", title: `查看“${query.trim()}”的全部结果`, subtitle: "按类型筛选 · Ctrl+Enter", run: go(() => navigate({ page: "search", searchQuery: query.trim() })) });
      if (isReady("confluence")) {
        list.push({ id: "wiki-search", icon: Search, group: "搜索", title: `在 Wiki 中搜索“${query.trim()}”`, subtitle: "按空间、时间筛选", run: go(() => navigate({ page: "wiki", wikiSearch: query.trim() })) });
      }
    }
    for (const h of results?.workspace ?? []) {
      const icon = h.itemType === "todo" && !h.done ? Square : HIT_ICONS[h.kind];
      list.push({ id: `ws-${h.itemType}-${h.id}`, icon, group: `工作空间`, title: h.title || "无标题", subtitle: `${HIT_GROUPS[h.kind]}${h.snippet ? ` · ${h.snippet}` : ""}`, run: go(() => navigate(backlinkTarget(h))) });
    }
    for (const i of results?.issues ?? []) {
      const subtitle = i.snippet ? `${i.snippet.source === "comment" ? `${i.snippet.author ?? ""} 的评论：` : "描述："}${i.snippet.text}` : i.project.name;
      list.push({ id: `issue-${i.key}`, icon: CircleDot, group: "Jira 问题", title: `${i.key} ${i.summary}`, subtitle, extra: <StatusPill status={i.status} />, run: go(() => navigate({ page: "jira", issueKey: i.key })) });
    }
    for (const w of results?.pages ?? []) {
      list.push({ id: `wiki-${w.id}`, icon: FileText, group: "Wiki 页面", title: w.title, subtitle: `${w.space}${w.excerpt ? ` · ${w.excerpt}` : ""}`, run: go(() => navigate({ page: "wiki", wikiPage: w.id })) });
    }
    for (const m of results?.mergeRequests ?? []) {
      list.push({ id: `mr-${m.id}`, icon: GitPullRequest, group: "GitLab 合并请求", title: `!${m.iid} ${m.title}`, subtitle: `${m.reference.split("!")[0]} · ${MR_STATES[m.state] ?? m.state}`, run: go(() => navigate({ page: "gitlab", projectId: m.projectId, mrIid: m.iid })) });
    }
    for (const p of results?.projects ?? []) {
      list.push({ id: `project-${p.id}`, icon: FolderGit2, group: "GitLab 项目", title: p.name, subtitle: p.pathWithNamespace, run: go(() => navigate({ page: "gitlab", projectId: p.id })) });
    }
    for (const c of results?.clips ?? []) {
      list.push({ id: `clip-${c.id}`, icon: ClipboardList, group: "剪贴板", title: clipLine(c.text, c.title) || "（图片或文件）", subtitle: `${c.appName ?? ""}${c.appName ? " · " : ""}回车复制`, run: go(() => copyClip(c.id)) });
    }
    return list;
  }, [query, results, navigate, onClose, onQuickTodo, baseUrl, isReady]);

  useEffect(() => setActive(0), [query]);
  // 结果陆续返回时保持选中项在范围内
  useEffect(() => setActive((a) => Math.min(a, Math.max(items.length - 1, 0))), [items.length]);

  useEffect(() => {
    listRef.current?.querySelector(".palette-item.active")?.scrollIntoView({ block: "nearest" });
  }, [active]);

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setActive((a) => Math.min(a + 1, items.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setActive((a) => Math.max(a - 1, 0));
    } else if (e.key === "Enter" && e.ctrlKey) {
      e.preventDefault();
      if (searchable) openSearchPage();
    } else if (e.key === "Enter") {
      e.preventDefault();
      items[active]?.run();
    } else if (e.key === "Escape") {
      onClose();
    }
  };

  let lastGroup = "";
  return (
    <div className="modal-backdrop palette-backdrop" onMouseDown={(e) => e.target === e.currentTarget && onClose()}>
      <div className="palette" role="dialog" aria-label="全局搜索">
        <div className="palette-search">
          {searching ? <Loader2 size={18} className="spin" /> : <Search size={18} />}
          <input autoFocus className="palette-input" value={query} placeholder="搜索待办、笔记、问题、Wiki、代码、剪贴板，或粘贴链接…" onChange={(e) => setQuery(e.target.value)} onKeyDown={onKeyDown} />
        </div>
        <ul className="palette-list" ref={listRef}>
          {items.map((item, index) => {
            const header = item.group !== lastGroup ? item.group : null;
            lastGroup = item.group;
            return (
              <li key={item.id}>
                {header && <div className="palette-group">{header}</div>}
                <button className={`palette-item${index === active ? " active" : ""}`} onMouseEnter={() => setActive(index)} onClick={item.run}>
                  <item.icon size={15} />
                  <span className="ellipsis grow">
                    <Highlight text={item.title} query={searchable && item.group !== "搜索" ? query : ""} />
                    {item.subtitle && <span className="muted small"> · {item.subtitle}</span>}
                  </span>
                  {item.extra}
                </button>
              </li>
            );
          })}
        </ul>
        <div className="palette-footer muted small">
          {error ? error : results?.errors.length ? results.errors.join("；") : (
            <>
              <span><kbd>↑</kbd> <kbd>↓</kbd> 选择</span>
              <span><kbd>↵</kbd> 打开</span>
              <span><kbd>Ctrl</kbd> <kbd>Enter</kbd> 全部结果</span>
              <span><kbd>Esc</kbd> 关闭</span>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
