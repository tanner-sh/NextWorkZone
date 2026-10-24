import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { api, errorMessage, type CreateProject, type FieldInfo, type IndexStatus, type IssueDetail, type IssueHit, type IssueSummary, type JiraFilter } from "../../api";
import { Bookmark, ChevronDown, ChevronRight, Plus, RefreshCw, Search, SlidersHorizontal, X } from "lucide-react";
import { Avatar, ErrorBox, Modal, NotConfigured, Skeleton, StatusPill, SysImg } from "../../components/common";
import { useContextMenu, type MenuInput } from "../../components/ContextMenu";
import { toast } from "../../components/Toast";
import { formatTime } from "../../lib/format";
import { reminderLabel, useReminders } from "../../lib/reminders";
import { markViewed, useUnseen } from "../../lib/viewed";
import { Highlight, useIndexStatus } from "./IndexStatus";
import { useNav, usePageReturn } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { CreateIssueDialog } from "./CreateIssueDialog";
import { useIssueMenu } from "./issueMenu";
import { IssueView } from "./IssueView";
import { EMPTY_SEARCH, fieldSort, JQL_PRESETS as PRESETS, loadSavedQueries, searchJql, SORTS, storeSavedQueries, withOrder, type SavedQuery, type SearchForm, type SortId } from "./jql";

const PAGE_SIZE = 100;

type Mode = (typeof PRESETS)[number]["id"] | "search" | "jql";

const GROUPS = [
  { id: "none", label: "不分组" },
  { id: "status", label: "按状态" },
  { id: "project", label: "按项目" },
  { id: "priority", label: "按优先级" },
  { id: "assignee", label: "按经办人" },
] as const;
type GroupId = (typeof GROUPS)[number]["id"];

const VIEW_KEY = "nextworkzone.jira.view";
const SOURCE_KEY = "nextworkzone.jira.searchSource";

/** 关键词搜索的来源：本机问题库（即时、离线，可搜评论）或 Jira。 */
type SearchSource = "local" | "jira";

function loadSource(): SearchSource {
  try {
    return localStorage.getItem(SOURCE_KEY) === "jira" ? "jira" : "local";
  } catch {
    return "local";
  }
}

interface ListView {
  sort: SortId;
  group: GroupId;
  /** 每条问题下额外显示的字段 */
  fields: FieldInfo[];
}

/** 最多额外显示的字段数。 */
const MAX_FIELDS = 5;

function loadView(): ListView {
  const fallback: ListView = { sort: "default", group: "none", fields: [] };
  try {
    return { ...fallback, ...JSON.parse(localStorage.getItem(VIEW_KEY) ?? "{}") };
  } catch {
    return fallback;
  }
}

function groupOf(issue: IssueSummary, group: GroupId): string {
  switch (group) {
    case "status":
      return issue.status.name;
    case "project":
      return issue.project.name;
    case "priority":
      return issue.priority?.name ?? "无优先级";
    case "assignee":
      return issue.assignee ?? "未分配";
    default:
      return "";
  }
}

export function JiraPage() {
  const { isReady } = useSettings();
  const { current, navigate } = useNav();
  const [mode, setMode] = useState<Mode>("mine");
  /** 当前查询（不含排序调整）；`label` 为常用查询的名称 */
  const [query, setQuery] = useState<{ jql: string; label?: string }>({ jql: PRESETS[0].jql });
  const [customJql, setCustomJql] = useState("");
  const [form, setForm] = useState<SearchForm>(EMPTY_SEARCH);
  const [view, setView] = useState(loadView);
  const [source, setSource] = useState<SearchSource>(loadSource);
  const indexStatus = useIndexStatus();
  /** 本机搜索的结果（含匹配处的摘要）；不是本机搜索时为 null */
  const [hits, setHits] = useState<Map<string, IssueHit> | null>(null);
  const [issues, setIssues] = useState<IssueSummary[] | null>(null);
  const [total, setTotal] = useState(0);
  const [loading, setLoading] = useState(false);
  const [loadingMore, setLoadingMore] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [selected, setSelected] = useState<string | null>(current.issueKey ?? null);
  /** 菜单操作修改了问题后递增，让详情重新加载 */
  const [detailVersion, setDetailVersion] = useState(0);
  const [collapsed, setCollapsed] = useState<string[]>([]);
  const [creating, setCreating] = useState(false);
  const [createWarning, setCreateWarning] = useState<string | null>(null);
  const [filters, setFilters] = useState<JiraFilter[]>([]);
  const [saved, setSaved] = useState<SavedQuery[]>(loadSavedQueries);
  const [savingQuery, setSavingQuery] = useState(false);
  const [managing, setManaging] = useState(false);
  const requestId = useRef(0);
  const contextMenu = useContextMenu();
  const toolbarMenu = useContextMenu();

  const jql = withOrder(query.jql, view.sort);
  const fieldIds = useMemo(() => view.fields.map((f) => f.id), [view.fields]);
  const [choosingFields, setChoosingFields] = useState(false);

  // 从其他页面（概览、全局搜索、相似问题）跳转过来
  useEffect(() => {
    if (current.page !== "jira") return;
    if (current.issueKey) setSelected(current.issueKey);
    if (current.jql) {
      setMode("jql");
      setCustomJql(current.jql);
      setQuery({ jql: current.jql });
    }
  }, [current]);

  useEffect(() => {
    try {
      localStorage.setItem(VIEW_KEY, JSON.stringify(view));
    } catch {
      // 不记忆
    }
  }, [view]);

  useEffect(() => {
    if (isReady("jira")) api.jiraFavouriteFilters().then(setFilters, () => setFilters([]));
  }, [isReady]);

  const load = useCallback(async (q: string, fields: string[]) => {
    const id = ++requestId.current;
    setError(null);
    setLoading(true);
    const cached = await api.jiraCachedSearch(q, fields).catch(() => null);
    if (id === requestId.current && cached) {
      setIssues(cached.issues);
      setTotal(cached.total);
    }
    try {
      const result = await api.jiraSearch(q, 0, PAGE_SIZE, fields);
      if (id !== requestId.current) return;
      setIssues(result.issues);
      setTotal(result.total);
    } catch (e) {
      if (id === requestId.current) {
        setError(errorMessage(e));
        if (!cached) setIssues([]);
      }
    } finally {
      if (id === requestId.current) setLoading(false);
    }
  }, []);

  // 本机问题库还没有数据时只能用 Jira 搜索
  const localSearch = mode === "search" && source === "local" && (indexStatus?.count ?? 0) > 0;

  useEffect(() => {
    if (isReady("jira") && !localSearch) {
      setHits(null);
      void load(jql, fieldIds);
    }
  }, [jql, fieldIds, load, isReady, localSearch]);

  // 回到 Jira 页面时在原地刷新列表（本机搜索的结果不需要）；加载过更多时不刷新，免得列表变短
  usePageReturn(() => {
    if (isReady("jira") && !localSearch && (issues?.length ?? 0) <= PAGE_SIZE) void load(jql, fieldIds);
  });

  // 本机搜索：输入时即时搜索
  useEffect(() => {
    if (!localSearch || !searchJql(form)) return;
    const id = ++requestId.current;
    const timer = window.setTimeout(() => {
      setError(null);
      api.jiraIndexSearch({ text: form.text, project: form.project, state: form.state, mine: form.who === "me", limit: 200 }).then(
        (list) => {
          if (id !== requestId.current) return;
          setHits(new Map(list.map((h) => [h.key, h])));
          setIssues(list);
          setTotal(list.length);
          setLoading(false);
        },
        (e) => id === requestId.current && setError(errorMessage(e)),
      );
    }, 120);
    return () => window.clearTimeout(timer);
  }, [localSearch, form, indexStatus?.lastSync]);

  const isUnseen = useUnseen(issues);
  const reminders = useReminders();
  const reminderOf = useMemo(() => new Map((reminders?.items ?? []).map((r) => [r.key, r])), [reminders]);

  const loadMore = async () => {
    if (!issues) return;
    const id = requestId.current;
    setLoadingMore(true);
    try {
      const result = await api.jiraSearch(jql, issues.length, PAGE_SIZE, fieldIds);
      if (id !== requestId.current) return;
      setIssues((list) => [...(list ?? []), ...result.issues.filter((i) => !list?.some((x) => x.key === i.key))]);
      setTotal(result.total);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setLoadingMore(false);
    }
  };

  const visible = useMemo(() => {
    const q = filter.trim().toLowerCase();
    if (!issues || !q) return issues ?? [];
    return issues.filter((i) => `${i.key} ${i.summary} ${i.project.name} ${i.status.name} ${i.assignee ?? ""}`.toLowerCase().includes(q));
  }, [issues, filter]);

  const groups = useMemo(() => {
    if (view.group === "none") return [{ name: "", issues: visible }];
    const map = new Map<string, IssueSummary[]>();
    for (const issue of visible) {
      const name = groupOf(issue, view.group);
      map.set(name, [...(map.get(name) ?? []), issue]);
    }
    return [...map.entries()].map(([name, list]) => ({ name, issues: list }));
  }, [visible, view.group]);

  // 列表变化后若尚未选中任何问题，默认选中第一条
  useEffect(() => {
    if (!selected && visible.length > 0) setSelected(visible[0].key);
  }, [visible, selected]);

  const onIssueChanged = (updated: IssueSummary) => {
    setIssues((list) => list?.map((i) => (i.key === updated.key ? { ...i, ...pickSummary(updated) } : i)) ?? list);
  };

  const issueMenu = useIssueMenu((detail: IssueDetail) => {
    onIssueChanged(detail);
    void markViewed(detail).catch(() => {});
    if (detail.key === selected) setDetailVersion((v) => v + 1);
  });

  if (!isReady("jira")) {
    return (
      <section className="page">
        <NotConfigured label="Jira" onOpenSettings={() => navigate({ page: "settings" })} />
      </section>
    );
  }

  const chooseMode = (next: Mode) => {
    setMode(next);
    const preset = PRESETS.find((p) => p.id === next);
    if (preset) setQuery({ jql: preset.jql });
    if (next === "search") {
      const built = searchJql(form);
      if (built) setQuery({ jql: built });
    }
    // 切换到 JQL 时带上当前查询，方便在此基础上修改
    if (next === "jql" && !customJql.trim()) setCustomJql(query.jql);
  };

  const runQuery = (q: { jql: string; label?: string }) => {
    setMode("jql");
    setCustomJql(q.jql);
    setQuery(q);
  };

  const runSearch = (next: SearchForm) => {
    setForm(next);
    const built = searchJql(next);
    if (built) setQuery({ jql: built });
  };

  const chooseSource = (next: SearchSource) => {
    setSource(next);
    try {
      localStorage.setItem(SOURCE_KEY, next);
    } catch {
      // 不记忆
    }
  };

  const updateSaved = (list: SavedQuery[]) => {
    setSaved(list);
    storeSavedQueries(list);
  };

  const savedMenu = (): MenuInput[] => [
    filters.length > 0 && { label: "Jira 收藏的过滤器", disabled: true },
    ...filters.map((f) => ({ label: f.name, checked: query.jql === f.jql, onSelect: () => runQuery({ jql: f.jql, label: f.name }) })),
    filters.length > 0 && "separator",
    saved.length > 0 && { label: "本机保存的查询", disabled: true },
    ...saved.map((q) => ({ label: q.name, checked: query.jql === q.jql, onSelect: () => runQuery(q) })),
    saved.length > 0 && "separator",
    { label: "保存当前查询…", icon: <Plus size={14} />, onSelect: () => setSavingQuery(true) },
    saved.length > 0 && { label: "管理保存的查询…", onSelect: () => setManaging(true) },
  ];

  const sortItem = (id: SortId, label: string) => ({ label, checked: view.sort === id, onSelect: () => setView((v) => ({ ...v, sort: id })) });
  const viewMenu = (): MenuInput[] => [
    {
      label: "排序",
      children: [
        ...SORTS.map((s) => sortItem(s.id, s.id === "default" ? (mode === "search" && form.text.trim() ? "按相关度" : "默认") : s.label)),
        // 额外显示的字段也可以用来排序（例如按截止日期从早到晚）
        view.fields.length > 0 && "separator",
        ...view.fields.flatMap((f) => [sortItem(fieldSort(f.id, "asc"), `${f.name} ↑`), sortItem(fieldSort(f.id, "desc"), `${f.name} ↓`)]),
      ],
    },
    { label: "分组", children: GROUPS.map((g) => ({ label: g.label, checked: view.group === g.id, onSelect: () => setView((v) => ({ ...v, group: g.id })) })) },
    "separator",
    { label: view.fields.length > 0 ? `显示字段（${view.fields.length}）…` : "显示更多字段…", onSelect: () => setChoosingFields(true) },
  ];

  const toggleGroup = (name: string) => setCollapsed((list) => (list.includes(name) ? list.filter((n) => n !== name) : [...list, name]));
  // 自己的未解决问题经办人都是自己，显示报告人更有用
  const personOf = (issue: IssueSummary) => (mode === "mine" ? issue.reporter : issue.assignee);

  return (
    <div className="split">
      <aside className="list-pane">
        <div className="list-toolbar">
          <div className="segmented">
            {PRESETS.map((p) => (
              <button key={p.id} className={mode === p.id ? "active" : ""} onClick={() => chooseMode(p.id)}>
                {p.label}
              </button>
            ))}
            <button className={mode === "search" ? "active" : ""} onClick={() => chooseMode("search")}>
              搜索
            </button>
            <button className={mode === "jql" ? "active" : ""} onClick={() => chooseMode("jql")}>
              JQL
            </button>
          </div>
          {mode === "search" && <SearchPanel form={form} onSearch={runSearch} source={source} onSource={chooseSource} index={indexStatus} />}
          {mode === "jql" && (
            <form
              className="jql-form"
              onSubmit={(e) => {
                e.preventDefault();
                if (customJql.trim()) setQuery({ jql: customJql.trim() });
              }}
            >
              <input value={customJql} placeholder="输入 JQL，回车查询" onChange={(e) => setCustomJql(e.target.value)} />
            </form>
          )}
          <div className="list-meta">
            <div className="input-icon">
              <Search size={14} />
              <input value={filter} placeholder="筛选当前列表" onChange={(e) => setFilter(e.target.value)} />
            </div>
            <button className={`btn subtle icon${toolbarMenu.target === "saved" ? " active" : ""}`} title="常用查询" onClick={(e) => toolbarMenu.open(e, savedMenu(), "saved")}>
              <Bookmark size={15} />
            </button>
            <button className={`btn subtle icon${view.sort !== "default" || view.group !== "none" ? " on" : ""}`} title="排序与分组" onClick={(e) => toolbarMenu.open(e, viewMenu(), "view")}>
              <SlidersHorizontal size={15} />
            </button>
            <button className="btn subtle icon" onClick={() => load(jql, fieldIds)} disabled={loading} title="刷新">
              <RefreshCw size={15} className={loading ? "spin" : ""} />
            </button>
            <button className="btn primary icon" onClick={() => setCreating(true)} title="新建问题">
              <Plus size={16} />
            </button>
          </div>
          <div className="muted small">
            {query.label && <strong className="query-label">{query.label} · </strong>}
            {issues && !(mode === "search" && !searchJql(form))
              ? localSearch
                ? `本机问题库中找到 ${total >= 200 ? "200+" : total} 条`
                : `共 ${total} 条${total > issues.length ? `，已显示 ${issues.length} 条` : ""}`
              : ""}
          </div>
        </div>
        {error && <ErrorBox message={error} onRetry={() => load(jql, fieldIds)} />}
        {createWarning && <ErrorBox message={createWarning} />}
        {mode === "search" && !searchJql(form) ? (
          <div className="list-empty muted small">
            输入关键词搜索问题，例如报错信息、功能名称，多个关键词用空格分开。可以限定项目、只看已解决的，找同事处理过的类似问题。
            {source === "local" && (indexStatus?.count ?? 0) > 0 && " 本机问题库会同时搜索描述和评论，输入即出结果。"}
          </div>
        ) : (
          <ul className="issue-list">
            {groups.map((g) => (
              <li key={g.name} className="issue-group">
                {g.name && (
                  <button className="group-header" onClick={() => toggleGroup(g.name)}>
                    {collapsed.includes(g.name) ? <ChevronRight size={13} /> : <ChevronDown size={13} />}
                    <span className="ellipsis">{g.name}</span>
                    <span className="muted">{g.issues.length}</span>
                  </button>
                )}
                {!collapsed.includes(g.name) && (
                  <ul>
                    {g.issues.map((issue) => (
                      <li key={issue.key}>
                        <button
                          className={`issue-item${selected === issue.key ? " selected" : ""}${contextMenu.target === issue.key ? " menu-target" : ""}`}
                          onClick={() => setSelected(issue.key)}
                          onContextMenu={(e) => contextMenu.open(e, issueMenu.menuFor(issue), issue.key)}
                        >
                          <div className="issue-item-top">
                            {isUnseen(issue) && <span className="unseen-dot" title="上次查看之后有新变化" />}
                            <SysImg service="jira" src={issue.issueType.iconUrl} className="icon16" alt={issue.issueType.name} />
                            <span className="issue-key">{issue.key}</span>
                            {!issue.resolution && reminderOf.get(issue.key) && (
                              <span className={`due-chip ${reminderOf.get(issue.key)!.kind}`}>{reminderLabel(reminderOf.get(issue.key)!.kind, reminderOf.get(issue.key)!.days)}</span>
                            )}
                            {issue.resolution && issue.status.category === "done" && <span className="muted small ellipsis">{issue.resolution}</span>}
                            <StatusPill status={issue.status} />
                          </div>
                          <div className="issue-summary">{hits ? <Highlight text={issue.summary} query={form.text} /> : issue.summary}</div>
                          {hits?.get(issue.key)?.snippet && (
                            <div className="hit-snippet small">
                              <span className="muted">{hits.get(issue.key)!.snippet!.source === "comment" ? `${hits.get(issue.key)!.snippet!.author}：` : "描述："}</span>
                              <Highlight text={hits.get(issue.key)!.snippet!.text} query={form.text} />
                            </div>
                          )}
                          {view.fields.some((f) => issue.extra?.[f.id]) && (
                            // 额外字段排成一行（名称灰色、值正常色），放不下时截断，悬停看全部
                            <div className="issue-extra small" title={view.fields.filter((f) => issue.extra?.[f.id]).map((f) => `${f.name}：${issue.extra![f.id]}`).join("\n")}>
                              {view.fields.map(
                                (f) =>
                                  issue.extra?.[f.id] && (
                                    <span key={f.id}>
                                      <span className="muted">{f.name} </span>
                                      {f.kind === "datetime" ? formatTime(issue.extra[f.id]) : issue.extra[f.id]}
                                    </span>
                                  ),
                              )}
                            </div>
                          )}
                          <div className="issue-item-bottom muted small">
                            <span className="ellipsis">{issue.project.name}</span>
                            <span className="nowrap">{formatTime(issue.updated)}</span>
                            {personOf(issue) && (
                              <span className="nowrap person" title={mode === "mine" ? `报告人：${issue.reporter}` : `经办人：${issue.assignee}`}>
                                <Avatar name={personOf(issue)!} size={18} />
                                {mode !== "mine" && personOf(issue)}
                              </span>
                            )}
                          </div>
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
              </li>
            ))}
            {!issues && !error && (
              <li style={{ padding: "8px 12px" }}>
                <Skeleton lines={8} height={16} />
              </li>
            )}
            {issues && visible.length === 0 && <li className="muted list-empty">没有匹配的问题</li>}
            {issues && total > issues.length && !filter && (
              <li className="load-more">
                <button className="btn" disabled={loadingMore} onClick={loadMore}>
                  {loadingMore ? "加载中…" : `加载更多（还有 ${total - issues.length} 条）`}
                </button>
              </li>
            )}
          </ul>
        )}
      </aside>
      <section className="detail-pane">
        {selected ? <IssueView key={`${selected}:${detailVersion}`} issueKey={selected} onChanged={onIssueChanged} /> : <div className="empty-center">选择左侧的问题查看详情</div>}
      </section>
      {contextMenu.menu}
      {toolbarMenu.menu}
      {issueMenu.dialogs}
      {creating && (
        <CreateIssueDialog
          onClose={() => setCreating(false)}
          onCreated={(key, warning) => {
            setCreating(false);
            setCreateWarning(warning ? `已创建 ${key}，但${warning}` : null);
            setSelected(key);
            void load(jql, fieldIds);
          }}
        />
      )}
      {savingQuery && (
        <SaveQueryDialog
          jql={query.jql}
          initialName={query.label ?? ""}
          onClose={() => setSavingQuery(false)}
          onSave={(name) => {
            updateSaved([...saved.filter((q) => q.name !== name), { name, jql: query.jql }]);
            setQuery({ ...query, label: name });
            setSavingQuery(false);
            toast(`已保存“${name}”`);
          }}
        />
      )}
      {managing && <ManageQueriesDialog saved={saved} onChange={updateSaved} onClose={() => setManaging(false)} />}
      {choosingFields && (
        <FieldChooser
          selected={view.fields}
          onClose={() => setChoosingFields(false)}
          onChange={(fields) =>
            // 去掉的字段如果正用于排序，改回默认排序
            setView((v) => ({ ...v, fields, sort: v.sort.startsWith("field:") && !fields.some((f) => v.sort.startsWith(`field:${f.id}:`)) ? "default" : v.sort }))
          }
        />
      )}
    </div>
  );
}

/** 关键词搜索：关键词、项目、解决状态、是否我经办过；可选本机问题库或 Jira。 */
function SearchPanel(props: { form: SearchForm; onSearch: (form: SearchForm) => void; source: SearchSource; onSource: (s: SearchSource) => void; index: IndexStatus | null }) {
  const { form, onSearch, index } = props;
  const [draft, setDraft] = useState(form);
  const [jiraProjects, setJiraProjects] = useState<CreateProject[]>([]);
  useEffect(() => {
    api.jiraCachedCreateProjects().then((cached) => cached && setJiraProjects(cached), () => {});
    api.jiraCreateProjects().then(setJiraProjects, () => {});
  }, []);
  const local = props.source === "local" && (index?.count ?? 0) > 0;
  // 本机问题库只能按已同步的项目筛选
  const projects = local ? (index?.projects ?? []) : jiraProjects;
  // 下拉选项修改后立即搜索；关键词在本机搜索时即时搜索，Jira 搜索时回车搜索
  const change = (patch: Partial<SearchForm>) => {
    const next = { ...draft, ...patch };
    setDraft(next);
    if (!("text" in patch) || local) onSearch(next);
  };
  return (
    <form
      className="search-panel"
      onSubmit={(e) => {
        e.preventDefault();
        onSearch(draft);
      }}
    >
      <div className="input-icon">
        <Search size={14} />
        <input autoFocus value={draft.text} placeholder="关键词或问题键，回车搜索" onChange={(e) => change({ text: e.target.value })} />
      </div>
      <div className="search-options">
        <select value={draft.project} onChange={(e) => change({ project: e.target.value })} title="项目">
          <option value="">全部项目</option>
          {projects.map((p) => (
            <option key={p.key} value={p.key}>
              {p.name}
            </option>
          ))}
        </select>
        <select value={draft.state} onChange={(e) => change({ state: e.target.value as SearchForm["state"] })} title="解决状态">
          <option value="all">全部状态</option>
          <option value="unresolved">未解决</option>
          <option value="resolved">已解决</option>
        </select>
        <select value={draft.who} onChange={(e) => change({ who: e.target.value as SearchForm["who"] })} title="经办人">
          <option value="anyone">所有人</option>
          <option value="me">{local ? "我参与过的" : "我经办过的"}</option>
        </select>
        <select value={props.source} onChange={(e) => props.onSource(e.target.value as SearchSource)} title={index?.count ? `本机问题库有 ${index.count} 个问题` : "搜索范围"}>
          <option value="local" disabled={!index?.enabled}>
            本机
          </option>
          <option value="jira">Jira</option>
        </select>
      </div>
      {props.source === "local" && index?.enabled && !index.count && (
        <p className="muted small">{index.running ? `本机问题库正在建立${index.progress ? `（${index.progress.scope} ${index.progress.done}/${index.progress.total}）` : ""}，暂时使用 Jira 搜索。` : "本机问题库还没有数据，暂时使用 Jira 搜索。"}</p>
      )}
    </form>
  );
}

/** 选择列表中额外显示的字段（最多 5 个）。 */
function FieldChooser({ selected, onChange, onClose }: { selected: FieldInfo[]; onChange: (fields: FieldInfo[]) => void; onClose: () => void }) {
  const [all, setAll] = useState<FieldInfo[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  useEffect(() => {
    // 先显示缓存，再取最新的字段列表（Jira 中可能新增了字段）
    api
      .jiraFields()
      .then(setAll, () => {})
      .then(() => api.jiraFields(true))
      .then(setAll, (e) => setError(errorMessage(e)));
  }, []);
  // 列表本身已显示的字段不再提供
  const shown = new Set(["summary", "status", "issuetype", "project", "updated", "assignee", "reporter", "resolution", "issuekey", "thumbnail"]);
  const q = filter.trim().toLowerCase();
  const candidates = (all ?? []).filter((f) => !shown.has(f.id) && !selected.some((s) => s.id === f.id) && (!q || f.name.toLowerCase().includes(q) || f.id.includes(q)));
  const full = selected.length >= MAX_FIELDS;
  return (
    <Modal
      title="列表显示的字段"
      onClose={onClose}
      footer={
        <button className="btn primary" onClick={onClose}>
          完成
        </button>
      }
    >
      <p className="muted small">选中的字段显示在每条问题的概要下方，也可以在“排序”中按这些字段排序。最多 {MAX_FIELDS} 个。</p>
      {selected.length > 0 && (
        <div className="chosen-fields">
          {selected.map((f) => (
            <span key={f.id} className="chip">
              {f.name}
              <button type="button" onClick={() => onChange(selected.filter((x) => x.id !== f.id))} aria-label={`移除 ${f.name}`}>
                <X size={11} />
              </button>
            </span>
          ))}
        </div>
      )}
      <div className="input-icon">
        <Search size={14} />
        <input value={filter} placeholder="搜索字段名称" onChange={(e) => setFilter(e.target.value)} />
      </div>
      {error && <ErrorBox message={error} />}
      {!all && !error && <Skeleton lines={5} />}
      <ul className="field-candidates">
        {candidates.slice(0, 200).map((f) => (
          <li key={f.id}>
            <button disabled={full} onClick={() => onChange([...selected, f])} title={full ? `最多选择 ${MAX_FIELDS} 个字段` : f.id}>
              <span>{f.name}</span>
              <span className="muted small">{f.custom ? "自定义" : "系统"} · {KIND_NAMES[f.kind] ?? f.kind}</span>
            </button>
          </li>
        ))}
      </ul>
    </Modal>
  );
}

const KIND_NAMES: Record<string, string> = { date: "日期", datetime: "时间", array: "多选", user: "用户", string: "文本", number: "数字", option: "单选", priority: "优先级", version: "版本" };

function SaveQueryDialog({ jql, initialName, onClose, onSave }: { jql: string; initialName: string; onClose: () => void; onSave: (name: string) => void }) {
  const [name, setName] = useState(initialName);
  return (
    <Modal
      title="保存当前查询"
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            取消
          </button>
          <button className="btn primary" disabled={!name.trim()} onClick={() => onSave(name.trim())}>
            保存
          </button>
        </>
      }
    >
      <label className="form-field">
        <span>名称</span>
        <input value={name} onChange={(e) => setName(e.target.value)} onKeyDown={(e) => e.key === "Enter" && !e.nativeEvent.isComposing && name.trim() && onSave(name.trim())} />
      </label>
      <div className="form-field">
        <span>JQL</span>
        <code className="jql-preview">{jql}</code>
      </div>
      <p className="muted small">保存在本机，点击工具栏的书签按钮即可使用。</p>
    </Modal>
  );
}

function ManageQueriesDialog({ saved, onChange, onClose }: { saved: SavedQuery[]; onChange: (list: SavedQuery[]) => void; onClose: () => void }) {
  return (
    <Modal
      title="保存的查询"
      onClose={onClose}
      footer={
        <button className="btn primary" onClick={onClose}>
          完成
        </button>
      }
    >
      {saved.length === 0 && <p className="muted">没有保存的查询</p>}
      <ul className="saved-queries">
        {saved.map((q, i) => (
          <li key={q.name}>
            <div className="grow">
              <div>{q.name}</div>
              <code className="jql-preview">{q.jql}</code>
            </div>
            <button className="btn subtle small-btn" disabled={i === 0} onClick={() => onChange([...saved.slice(0, i - 1), q, saved[i - 1], ...saved.slice(i + 1)])}>
              上移
            </button>
            <button className="btn subtle small-btn danger-text" onClick={() => onChange(saved.filter((x) => x !== q))}>
              删除
            </button>
          </li>
        ))}
      </ul>
    </Modal>
  );
}

function pickSummary(i: IssueSummary): IssueSummary {
  const { key, summary, status, issueType, priority, project, assignee, assigneeName, reporter, reporterName, lastViewed, resolution, created, updated, dueDate } = i;
  return { key, summary, status, issueType, priority, project, assignee, assigneeName, reporter, reporterName, lastViewed, resolution, created, updated, dueDate };
}
