import { useEffect, useRef, useState, type ReactNode } from "react";
import { CircleDot, ClipboardList, Copy, FileText, FolderGit2, GitPullRequest, Loader2, Search, Square } from "lucide-react";
import type { SearchResults } from "../api";
import { StatusPill } from "../components/common";
import { clipLine, copyClip, HIT_GROUPS, HIT_ICONS, MR_STATES } from "../components/CommandPalette";
import { useMenus } from "../components/MenuHost";
import { formatTime } from "../lib/format";
import { Highlight, useUnifiedSearch } from "../lib/search";
import { backlinkTarget } from "./workspace/Backlinks";
import { useNav, type NavTarget } from "../state/nav";

type Scope = "all" | "workspace" | "jira" | "wiki" | "gitlab" | "clipboard";

const SCOPES: [Scope, string][] = [
  ["all", "全部"],
  ["workspace", "工作空间"],
  ["jira", "Jira"],
  ["wiki", "Wiki"],
  ["gitlab", "GitLab"],
  ["clipboard", "剪贴板"],
];

/** 每类结果的条数；“全部”中每类只显示前几条。 */
const LIMIT = 50;
const PREVIEW = 5;

function count(results: SearchResults | null, scope: Scope): number {
  if (!results) return 0;
  switch (scope) {
    case "workspace":
      return results.workspace.length;
    case "jira":
      return results.issues.length;
    case "wiki":
      return results.pages.length;
    case "gitlab":
      return results.mergeRequests.length + results.projects.length;
    case "clipboard":
      return results.clips.length;
    default:
      return SCOPES.slice(1).reduce((n, [s]) => n + count(results, s), 0);
  }
}

/** 统一搜索：工作空间、Jira 问题、Wiki 页面、GitLab 合并请求和项目、剪贴板历史，按类型筛选。 */
export function SearchPage() {
  const { current } = useNav();
  const [input, setInput] = useState(current.searchQuery ?? "");
  const [scope, setScope] = useState<Scope>((SCOPES.find(([s]) => s === current.searchScope)?.[0] as Scope) ?? "all");
  const { results, pending, error } = useUnifiedSearch(input, LIMIT);
  const inputRef = useRef<HTMLInputElement>(null);

  // 从 ⌘K 再次进入时使用新的搜索文字
  useEffect(() => {
    if (current.page !== "search") return;
    if (current.searchQuery !== undefined) setInput(current.searchQuery);
    inputRef.current?.focus();
  }, [current]);

  const q = input.trim();
  const show = (s: Scope) => scope === "all" || scope === s;
  const take = <T,>(list: T[]) => (scope === "all" ? list.slice(0, PREVIEW) : list);
  const more = (s: Scope, n: number) =>
    scope === "all" && n > PREVIEW ? (
      <button className="link small search-more" onClick={() => setScope(s)}>
        查看全部 {n} 条
      </button>
    ) : null;

  return (
    <section className="page search-page">
      <header className="page-header">
        <div>
          <h1>搜索</h1>
          <p className="muted small">本机数据（待办、笔记、知识库、本机问题库和 Wiki 库、剪贴板）先显示，GitLab 等服务器结果随后补上。</p>
        </div>
      </header>
      <div className="input-icon search-input">
        {pending ? <Loader2 size={16} className="spin" /> : <Search size={16} />}
        <input ref={inputRef} autoFocus value={input} placeholder="输入至少两个字" onChange={(e) => setInput(e.target.value)} />
      </div>
      <div className="segmented">
        {SCOPES.map(([s, label]) => (
          <button key={s} className={scope === s ? "active" : ""} onClick={() => setScope(s)}>
            {label}
            {results && <span className="seg-count">{count(results, s)}</span>}
          </button>
        ))}
      </div>
      {error && <p className="notice error">{error}</p>}
      {results && results.errors.length > 0 && <p className="notice warn small">{results.errors.join("；")}</p>}
      {q.length < 2 && <p className="muted">输入至少两个字开始搜索。</p>}
      {results && q.length >= 2 && count(results, scope) === 0 && !pending && <p className="muted">没有找到相关内容。</p>}

      {results && (
        <>
          {show("workspace") && results.workspace.length > 0 && (
            <ResultGroup title="工作空间" n={results.workspace.length} more={more("workspace", results.workspace.length)}>
              {take(results.workspace).map((h) => {
                const Icon = h.itemType === "todo" && !h.done ? Square : HIT_ICONS[h.kind];
                return (
                  <Row key={`${h.itemType}-${h.id}`} icon={<Icon size={15} />} target={backlinkTarget(h)} title={h.title || "无标题"} query={q} meta={HIT_GROUPS[h.kind]} snippet={h.snippet} done={h.done} />
                );
              })}
            </ResultGroup>
          )}
          {show("jira") && results.issues.length > 0 && (
            <ResultGroup title="Jira 问题" note={results.issuesSource === "local" ? "本机问题库" : "Jira 搜索"} n={results.issues.length} more={more("jira", results.issues.length)}>
              {take(results.issues).map((i) => (
                <Row
                  key={i.key}
                  icon={<CircleDot size={15} />}
                  target={{ page: "jira", issueKey: i.key }}
                  issue={i}
                  title={`${i.key} ${i.summary}`}
                  query={q}
                  meta={[i.project.name, i.assignee, i.resolved ? `${formatTime(i.resolved)} 解决` : formatTime(i.updated)].filter(Boolean).join(" · ")}
                  snippet={i.snippet ? `${i.snippet.source === "comment" ? `${i.snippet.author ?? ""}：` : ""}${i.snippet.text}` : undefined}
                  extra={<StatusPill status={i.status} />}
                />
              ))}
            </ResultGroup>
          )}
          {show("wiki") && results.pages.length > 0 && (
            <ResultGroup title="Wiki 页面" n={results.pages.length} more={more("wiki", results.pages.length)}>
              {take(results.pages).map((w) => (
                <Row key={w.id} icon={<FileText size={15} />} target={{ page: "wiki", wikiPage: w.id }} wikiPage={w} title={w.title} query={q} meta={w.space} snippet={w.excerpt} />
              ))}
            </ResultGroup>
          )}
          {show("gitlab") && results.mergeRequests.length > 0 && (
            <ResultGroup title="GitLab 合并请求" n={results.mergeRequests.length} more={more("gitlab", count(results, "gitlab"))}>
              {take(results.mergeRequests).map((m) => (
                <Row
                  key={m.id}
                  icon={<GitPullRequest size={15} />}
                  target={{ page: "gitlab", projectId: m.projectId, mrIid: m.iid }}
                  title={`!${m.iid} ${m.title}`}
                  query={q}
                  meta={`${m.reference.split("!")[0]} · ${m.author.name} · ${formatTime(m.updatedAt)}`}
                  extra={<span className="tag muted-tag">{MR_STATES[m.state] ?? m.state}</span>}
                />
              ))}
            </ResultGroup>
          )}
          {show("gitlab") && results.projects.length > 0 && (
            <ResultGroup title="GitLab 项目" n={results.projects.length}>
              {take(results.projects).map((p) => (
                <Row key={p.id} icon={<FolderGit2 size={15} />} target={{ page: "gitlab", projectId: p.id }} title={p.name} query={q} meta={p.pathWithNamespace} snippet={p.description ?? undefined} />
              ))}
            </ResultGroup>
          )}
          {show("clipboard") && results.clips.length > 0 && (
            <ResultGroup title="剪贴板" n={results.clips.length} more={more("clipboard", results.clips.length)} note="点击复制">
              {take(results.clips).map((c) => (
                <Row
                  key={c.id}
                  icon={<ClipboardList size={15} />}
                  onOpen={() => copyClip(c.id)}
                  title={clipLine(c.text, c.title) || "（图片或文件）"}
                  query={q}
                  meta={[c.appName, formatTime(new Date(c.copiedAt).toISOString())].filter(Boolean).join(" · ")}
                  snippet={c.text.includes("\n") ? c.text : undefined}
                  extra={<ClipActions query={q} />}
                />
              ))}
            </ResultGroup>
          )}
        </>
      )}
    </section>
  );
}

function ResultGroup({ title, n, note, more, children }: { title: string; n: number; note?: string; more?: ReactNode; children: ReactNode }) {
  return (
    <div className="search-group">
      <h2>
        {title} <span className="count">{n}</span>
        {note && <span className="muted small">{note}</span>}
        <span className="spacer" />
        {more}
      </h2>
      <ul className="search-results">{children}</ul>
    </div>
  );
}

function Row(props: {
  icon: ReactNode;
  title: string;
  query: string;
  target?: NavTarget;
  onOpen?: () => void;
  meta?: string;
  snippet?: string;
  extra?: ReactNode;
  done?: boolean;
  issue?: Parameters<ReturnType<typeof useMenus>["issue"]>[0];
  wikiPage?: { id: string; title: string; space: string };
}) {
  const { navigate } = useNav();
  const menus = useMenus();
  const open = props.onOpen ?? (() => props.target && navigate(props.target));
  const menuKey = `search:${props.title}`;
  const onContextMenu = props.issue
    ? (e: React.MouseEvent) => menus.open(e, menus.issue(props.issue!), menuKey)
    : props.wikiPage
      ? (e: React.MouseEvent) => menus.open(e, menus.wikiPage(props.wikiPage!), menuKey)
      : undefined;
  return (
    <li>
      <div className={`search-row${menus.target === menuKey ? " menu-target" : ""}`} role="button" tabIndex={0} onClick={open} onKeyDown={(e) => e.key === "Enter" && open()} onContextMenu={onContextMenu}>
        <span className="search-row-icon muted">{props.icon}</span>
        <span className="search-row-body">
          <span className={`search-row-title ellipsis${props.done ? " strike" : ""}`}>
            <Highlight text={props.title} query={props.query} />
          </span>
          {props.meta && <span className="muted small ellipsis">{props.meta}</span>}
          {props.snippet && (
            <span className="search-row-snippet hit-snippet">
              <Highlight text={props.snippet} query={props.query} />
            </span>
          )}
        </span>
        {props.extra}
      </div>
    </li>
  );
}

/** 剪贴板结果：在剪贴板历史中查看。 */
function ClipActions({ query }: { query: string }) {
  const { navigate } = useNav();
  return (
    <span className="search-row-actions">
      <Copy size={13} className="muted" />
      <button
        className="link small"
        onClick={(e) => {
          e.stopPropagation();
          navigate({ page: "tools", tool: "clipboard", toolQuery: query });
        }}
      >
        在剪贴板中查看
      </button>
    </span>
  );
}

