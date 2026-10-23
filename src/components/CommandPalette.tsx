import { useEffect, useMemo, useRef, useState } from "react";
import { api, errorMessage, type SearchResults } from "../api";
import { useNav, type PageId } from "../state/nav";
import { BookOpen, CalendarDays, CheckSquare, CircleDot, CornerDownLeft, FileText, FolderGit2, Loader2, NotepadText, Plus, Search, Square, type LucideIcon } from "lucide-react";
import { backlinkTarget } from "../pages/workspace/Backlinks";
import { StatusPill } from "./common";
import { openLink, routeUrl } from "../lib/links";
import { useSettings } from "../state/settings";

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
  { page: "home", label: "今天", keywords: "home 首页 今天 概览 jt" },
  { page: "todos", label: "待办", keywords: "todo 待办 任务 db" },
  { page: "notes", label: "笔记", keywords: "notes 笔记 日记 bj rj" },
  { page: "kb", label: "知识库", keywords: "kb wiki 知识库 文档 zsk" },
  { page: "jira", label: "我的问题", keywords: "jira issue 问题 wt" },
  { page: "activity", label: "动态", keywords: "activity 动态 通知 提醒 dt tz" },
  { page: "weekly", label: "周报", keywords: "weekly wiki 周报 zb" },
  { page: "wiki", label: "Wiki", keywords: "wiki confluence 文档 页面 空间 wd" },
  { page: "gitlab", label: "代码", keywords: "gitlab code 代码 项目 dm" },
  { page: "stats", label: "统计", keywords: "stats 统计 报表 tj" },
  { page: "settings", label: "设置", keywords: "settings 设置 sz" },
];

const HIT_ICONS = { todo: CheckSquare, note: NotepadText, daily: CalendarDays, page: BookOpen } as const;
const HIT_GROUPS = { todo: "待办", note: "笔记", daily: "日记", page: "知识库" } as const;

/** ⌘K 全局搜索：页面跳转、新建待办，同时搜索工作空间和 Jira、GitLab、Wiki。 */
export function CommandPalette({ onClose, onQuickTodo }: { onClose: () => void; onQuickTodo: () => void }) {
  const { navigate } = useNav();
  const { baseUrl, isReady } = useSettings();
  const [query, setQuery] = useState("");
  const [results, setResults] = useState<SearchResults | null>(null);
  const [searching, setSearching] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [active, setActive] = useState(0);
  const listRef = useRef<HTMLUListElement>(null);

  // 输入停顿 300ms 后再搜索
  useEffect(() => {
    const q = query.trim();
    // 粘贴的地址不做全文搜索
    if (q.length < 2 || /^https?:\/\//.test(q)) {
      setResults(null);
      setSearching(false);
      return;
    }
    setSearching(true);
    let cancelled = false;
    const timer = setTimeout(() => {
      api.globalSearch(q).then(
        (r) => {
          if (cancelled) return;
          setResults(r);
          setError(null);
          setSearching(false);
        },
        (e) => {
          if (cancelled) return;
          setError(errorMessage(e));
          setSearching(false);
        },
      );
    }, 300);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [query]);

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
      list.push({ id: "action-todo", icon: Plus, group: "操作", title: "新建待办", subtitle: "⌘⇧N", run: go(onQuickTodo) });
    }
    for (const h of results?.workspace ?? []) {
      const icon = h.itemType === "todo" && !h.done ? Square : HIT_ICONS[h.kind];
      list.push({ id: `ws-${h.itemType}-${h.id}`, icon, group: `工作空间`, title: h.title || "无标题", subtitle: `${HIT_GROUPS[h.kind]}${h.snippet ? ` · ${h.snippet}` : ""}`, run: go(() => navigate(backlinkTarget(h))) });
    }
    for (const i of results?.issues ?? []) {
      list.push({ id: `issue-${i.key}`, icon: CircleDot, group: "Jira 问题", title: `${i.key} ${i.summary}`, subtitle: i.project.name, extra: <StatusPill status={i.status} />, run: go(() => navigate({ page: "jira", issueKey: i.key })) });
    }
    for (const p of results?.projects ?? []) {
      list.push({ id: `project-${p.id}`, icon: FolderGit2, group: "GitLab 项目", title: p.name, subtitle: p.pathWithNamespace, run: go(() => navigate({ page: "gitlab", projectId: p.id })) });
    }
    for (const w of results?.pages ?? []) {
      list.push({ id: `wiki-${w.id}`, icon: FileText, group: "Wiki 页面", title: w.title, subtitle: `${w.space}${w.excerpt ? ` · ${w.excerpt}` : ""}`, run: go(() => navigate({ page: "wiki", wikiPage: w.id })) });
    }
    if (q.length >= 2 && !/^https?:\/\//.test(q) && isReady("confluence")) {
      list.push({ id: "wiki-search", icon: Search, group: "Wiki 页面", title: `在 Wiki 中搜索“${query.trim()}”`, subtitle: "按空间、时间筛选", run: go(() => navigate({ page: "wiki", wikiSearch: query.trim() })) });
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
          <input autoFocus className="palette-input" value={query} placeholder="搜索待办、笔记、知识库、问题、Wiki、项目，或粘贴链接…" onChange={(e) => setQuery(e.target.value)} onKeyDown={onKeyDown} />
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
                    {item.title}
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
              <span><kbd>Esc</kbd> 关闭</span>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
