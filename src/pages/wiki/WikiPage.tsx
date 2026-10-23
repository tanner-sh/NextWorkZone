import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { BookText, ChevronDown, ChevronRight, Clock3, FileText, Folder, Globe, Loader2, Plus, RefreshCw, Search, Star } from "lucide-react";
import { api, errorMessage, type WikiNode, type WikiPageDetail, type WikiPageHit, type WikiRecent, type WikiSpace } from "../../api";
import { ErrorBox, NotConfigured, Skeleton } from "../../components/common";
import { useMenus } from "../../components/MenuHost";
import { formatTime } from "../../lib/format";
import { useFavorites } from "../../lib/wiki";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { NewPageDialog, type NewPageRequest } from "./NewPageDialog";
import { PageEditor } from "./PageEditor";
import { PageView } from "./PageView";

type Tab = "recent" | "favorites" | "spaces" | "search";
const TAB_KEY = "nextworkzone.wiki.tab";
const LAST_PAGE_KEY = "nextworkzone.wiki.lastPage";

function saved<T extends string>(key: string, fallback: T): T {
  try {
    return (localStorage.getItem(key) as T | null) ?? fallback;
  } catch {
    return fallback;
  }
}

function remember(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // 不记忆
  }
}

/** 正在编辑的页面，或正在新建的页面。 */
type Editing = { kind: "edit"; pageId: string } | { kind: "new"; request: NewPageRequest };

/** Wiki：最近、收藏、空间页面树、搜索，右侧阅读和编辑页面。 */
export function WikiPage() {
  const { isReady } = useSettings();
  const { current, navigate } = useNav();
  const [tab, setTab] = useState<Tab>(() => saved(TAB_KEY, "recent"));
  const [selected, setSelected] = useState<string | null>(() => current.wikiPage ?? (saved(LAST_PAGE_KEY, "") || null));
  const [anchor, setAnchor] = useState<string | undefined>(current.anchor);
  const [detail, setDetail] = useState<WikiPageDetail | null>(null);
  const [editing, setEditing] = useState<Editing | null>(null);
  const [creating, setCreating] = useState<{ space: string; parent: string | null } | null>(null);
  const [reloadKey, setReloadKey] = useState(0);
  const tree = useSpaceTree();

  // 从其他页面跳转过来（打开某个页面、搜索）
  useEffect(() => {
    if (current.page !== "wiki") return;
    if (current.wikiPage) {
      setSelected(current.wikiPage);
      setAnchor(current.anchor);
      setEditing(null);
    }
    if (current.wikiSearch !== undefined) setTab("search");
  }, [current]);

  const switchTab = (next: Tab) => {
    setTab(next);
    remember(TAB_KEY, next);
  };

  const open = useCallback((id: string) => {
    setSelected(id);
    setAnchor(undefined);
    setEditing(null);
    remember(LAST_PAGE_KEY, id);
  }, []);

  const onLoaded = useCallback(
    (page: WikiPageDetail) => {
      setDetail(page);
      remember(LAST_PAGE_KEY, page.id);
      // 解析过的地址换成页面 id，刷新时不用再解析
      setSelected((s) => (s === page.id ? s : page.id));
      tree.reveal(page);
    },
    [tree.reveal],
  );

  if (!isReady("confluence")) {
    return (
      <section className="page">
        <NotConfigured label="Wiki" onOpenSettings={() => navigate({ page: "settings" })} />
      </section>
    );
  }

  return (
    <div className="split">
      <aside className="list-pane wiki-sidebar">
        <div className="list-toolbar">
          <div className="segmented small-seg wiki-tabs">
            <button className={tab === "recent" ? "active" : ""} onClick={() => switchTab("recent")}>
              <Clock3 size={13} />
              最近
            </button>
            <button className={tab === "favorites" ? "active" : ""} onClick={() => switchTab("favorites")}>
              <Star size={13} />
              收藏
            </button>
            <button className={tab === "spaces" ? "active" : ""} onClick={() => switchTab("spaces")}>
              <Folder size={13} />
              空间
            </button>
            <button className={tab === "search" ? "active" : ""} onClick={() => switchTab("search")}>
              <Search size={13} />
              搜索
            </button>
          </div>
        </div>
        {tab === "recent" && <RecentList selected={selected} onOpen={open} />}
        {tab === "favorites" && <FavoriteList selected={selected} onOpen={open} />}
        {tab === "spaces" && <SpaceTree tree={tree} selected={selected} onOpen={open} onCreate={(space, parent) => setCreating({ space, parent })} />}
        {tab === "search" && <SearchPanel initial={current.wikiSearch} spaces={tree.spaces ?? []} selected={selected} onOpen={open} />}
      </aside>
      <section className="detail-pane">
        {editing ? (
          <PageEditor
            key={editing.kind === "edit" ? editing.pageId : "new"}
            target={editing}
            onClose={() => setEditing(null)}
            onSaved={(id) => {
              setEditing(null);
              setSelected(id);
              setReloadKey((k) => k + 1);
              if (editing.kind === "new") tree.refreshChildren(editing.request.parent ?? `space:${editing.request.space}`);
            }}
          />
        ) : selected ? (
          <PageView
            key={`${selected}-${reloadKey}`}
            pageId={selected}
            anchor={anchor}
            onOpen={open}
            onLoaded={onLoaded}
            onEdit={() => setEditing({ kind: "edit", pageId: selected })}
            onNewChild={() => detail && setCreating({ space: detail.spaceKey, parent: detail.id })}
          />
        ) : (
          <div className="empty-center">
            <BookText size={28} className="muted" />
            <div className="muted">从左侧选择页面，或搜索 Wiki</div>
          </div>
        )}
      </section>
      {creating && (
        <NewPageDialog
          space={creating.space}
          parent={creating.parent}
          onClose={() => setCreating(null)}
          onStart={(request) => {
            setCreating(null);
            setEditing({ kind: "new", request });
          }}
        />
      )}
    </div>
  );
}

// ---------- 最近、收藏 ----------

/** 列表项的样式：选中、右键菜单所在。 */
const itemClass = (base: string, selected: boolean, menuTarget: boolean) => `${base}${selected ? " selected" : ""}${menuTarget ? " menu-target" : ""}`;

function RecentList({ selected, onOpen }: { selected: string | null; onOpen: (id: string) => void }) {
  const menus = useMenus();
  const [list, setList] = useState<WikiRecent[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(() => {
    setError(null);
    api.wikiRecent(50).then(setList, (e) => setError(errorMessage(e)));
  }, []);
  useEffect(load, [load]);
  return (
    <>
      {error && <ErrorBox message={error} onRetry={load} />}
      {!list && !error && (
        <div style={{ padding: "8px 12px" }}>
          <Skeleton lines={8} height={16} />
        </div>
      )}
      <ul className="doc-list">
        {list?.map((p) => (
          <li key={p.id}>
            <button className={itemClass("doc-item", selected === p.id, menus.target === p.id)} onClick={() => onOpen(p.id)} onContextMenu={(e) => menus.open(e, menus.wikiPage(p), p.id)}>
              <span className="doc-item-title">{p.title}</span>
              <span className="doc-item-excerpt muted small">
                {p.space} · {formatTime(new Date(p.at).toISOString())}
                {p.source === "web" && " · 网页上查看"}
              </span>
            </button>
          </li>
        ))}
        {list?.length === 0 && <li className="muted list-empty">还没有查看过 Wiki 页面</li>}
      </ul>
    </>
  );
}

function FavoriteList({ selected, onOpen }: { selected: string | null; onOpen: (id: string) => void }) {
  const favorites = useFavorites();
  const menus = useMenus();
  return (
    <ul className="doc-list">
      {favorites.map((p) => (
        <li key={p.id}>
          <button className={itemClass("doc-item", selected === p.id, menus.target === p.id)} onClick={() => onOpen(p.id)} onContextMenu={(e) => menus.open(e, menus.wikiPage(p), p.id)}>
            <span className="doc-item-title">{p.title}</span>
            <span className="doc-item-excerpt muted small">{p.space}</span>
          </button>
        </li>
      ))}
      {favorites.length === 0 && <li className="muted list-empty">点击页面标题旁的星标收藏常看的页面</li>}
    </ul>
  );
}

// ---------- 空间与页面树 ----------

type Children = WikiNode[] | "loading" | { error: string };

interface SpaceTreeState {
  spaces: WikiSpace[] | null;
  error: string | null;
  children: Record<string, Children>;
  expanded: Set<string>;
  loadSpaces: () => void;
  toggle: (id: string) => void;
  reveal: (page: WikiPageDetail) => void;
  refreshChildren: (id: string) => void;
}

/** 空间列表与按需加载的页面树。节点 id：空间为 `space:<key>`，页面为页面 id。 */
function useSpaceTree(): SpaceTreeState {
  const [spaces, setSpaces] = useState<WikiSpace[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [children, setChildren] = useState<Record<string, Children>>({});
  const [expanded, setExpanded] = useState<Set<string>>(new Set());

  const loadSpaces = useCallback(() => {
    setError(null);
    api.wikiCachedSpaces().then((cached) => cached && setSpaces((s) => s ?? cached), () => {});
    api.wikiSpaces().then(setSpaces, (e) => setError(errorMessage(e)));
  }, []);
  useEffect(loadSpaces, [loadSpaces]);

  // 已请求过的节点（避免重复请求；状态更新函数里不能发请求）
  const requested = useRef(new Set<string>());
  const fetchChildren = useCallback((id: string, force = false) => {
    if (requested.current.has(id) && !force) return;
    requested.current.add(id);
    setChildren((m) => (Array.isArray(m[id]) ? m : { ...m, [id]: "loading" }));
    const request = id.startsWith("space:") ? api.wikiSpaceRoots(id.slice(6)) : api.wikiChildren(id);
    request.then(
      (list) => setChildren((m) => ({ ...m, [id]: list })),
      (e) => {
        requested.current.delete(id);
        setChildren((m) => ({ ...m, [id]: { error: errorMessage(e) } }));
      },
    );
  }, []);

  const toggle = useCallback(
    (id: string) => {
      const opening = !expanded.has(id);
      if (opening) fetchChildren(id);
      setExpanded((set) => {
        const next = new Set(set);
        if (opening) next.add(id);
        else next.delete(id);
        return next;
      });
    },
    [expanded, fetchChildren],
  );

  // 打开页面时展开它所在的空间和各级上级页面
  const reveal = useCallback(
    (page: WikiPageDetail) => {
      const chain = [`space:${page.spaceKey}`, ...page.ancestors.map((a) => a.id)];
      setExpanded((set) => {
        const next = new Set(set);
        chain.forEach((id) => next.add(id));
        return next;
      });
      chain.forEach((id) => fetchChildren(id));
    },
    [fetchChildren],
  );

  const refreshChildren = useCallback((id: string) => fetchChildren(id, true), [fetchChildren]);

  return { spaces, error, children, expanded, loadSpaces, toggle, reveal, refreshChildren };
}

function SpaceTree({ tree, selected, onOpen, onCreate }: { tree: SpaceTreeState; selected: string | null; onOpen: (id: string) => void; onCreate: (space: string, parent: string | null) => void }) {
  const menus = useMenus();
  const [filter, setFilter] = useState("");
  const visible = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return (tree.spaces ?? []).filter((s) => !q || `${s.name} ${s.key}`.toLowerCase().includes(q));
  }, [tree.spaces, filter]);

  const renderChildren = (id: string, space: WikiSpace, depth: number): React.ReactNode => {
    const list = tree.children[id];
    if (list === undefined || list === "loading") {
      return (
        <li className="muted small tree-loading" style={{ paddingLeft: 8 + depth * 14 }}>
          <Loader2 size={12} className="spin" /> 加载中…
        </li>
      );
    }
    if (!Array.isArray(list)) {
      return (
        <li className="muted small" style={{ paddingLeft: 8 + depth * 14 }}>
          {list.error}
        </li>
      );
    }
    if (list.length === 0) {
      return (
        <li className="muted small" style={{ paddingLeft: 8 + depth * 14 }}>
          没有页面
        </li>
      );
    }
    return list.map((node) => {
      const open = tree.expanded.has(node.id);
      return (
        <li key={node.id}>
          <div
            className={itemClass("tree-item", selected === node.id, menus.target === node.id)}
            style={{ paddingLeft: 4 + depth * 14 }}
            onClick={() => onOpen(node.id)}
            onContextMenu={(e) =>
              menus.open(
                e,
                [
                  ...menus.wikiPage({ id: node.id, title: node.title, space: space.name }, { onNewChild: () => onCreate(space.key, node.id) }),
                  node.hasChildren && "separator",
                  node.hasChildren && { label: open ? "收起" : "展开", onSelect: () => tree.toggle(node.id) },
                  node.hasChildren && open && { label: "刷新子页面", onSelect: () => tree.refreshChildren(node.id) },
                ],
                node.id,
              )
            }
            title={node.title}
          >
            {node.hasChildren ? (
              <button
                className="tree-toggle"
                onClick={(e) => {
                  e.stopPropagation();
                  tree.toggle(node.id);
                }}
              >
                {open ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
              </button>
            ) : (
              <span className="tree-toggle">
                <FileText size={13} />
              </span>
            )}
            <span className="ellipsis grow">{node.title}</span>
            <button
              className="tree-add"
              title="新建子页面"
              onClick={(e) => {
                e.stopPropagation();
                onCreate(space.key, node.id);
              }}
            >
              <Plus size={13} />
            </button>
          </div>
          {open && node.hasChildren && <ul className="tree">{renderChildren(node.id, space, depth + 1)}</ul>}
        </li>
      );
    });
  };

  return (
    <>
      <div className="list-toolbar wiki-subtoolbar">
        <div className="list-meta">
          <div className="input-icon">
            <Search size={14} />
            <input value={filter} placeholder="筛选空间" onChange={(e) => setFilter(e.target.value)} />
          </div>
          <button className="btn subtle icon" title="刷新" onClick={tree.loadSpaces}>
            <RefreshCw size={15} />
          </button>
        </div>
      </div>
      {tree.error && <ErrorBox message={tree.error} onRetry={tree.loadSpaces} />}
      {!tree.spaces && !tree.error && (
        <div style={{ padding: "8px 12px" }}>
          <Skeleton lines={8} height={16} />
        </div>
      )}
      <ul className="tree root">
        {visible.map((s) => {
          const id = `space:${s.key}`;
          const open = tree.expanded.has(id);
          return (
            <li key={s.key}>
              <div
                className={itemClass("tree-item wiki-space", false, menus.target === id)}
                onClick={() => tree.toggle(id)}
                onContextMenu={(e) =>
                  menus.open(
                    e,
                    [
                      { label: open ? "收起" : "展开", onSelect: () => tree.toggle(id) },
                      "separator",
                      ...menus.wikiSpace(s, { onCreate: () => onCreate(s.key, null), onRefresh: open ? () => tree.refreshChildren(id) : undefined }),
                    ],
                    id,
                  )
                }
                title={s.description || s.name}
              >
                <span className="tree-toggle">{open ? <ChevronDown size={14} /> : <ChevronRight size={14} />}</span>
                <Globe size={13} className="muted" />
                <span className="ellipsis grow">{s.name}</span>
                {s.homepageId && (
                  <button
                    className="tree-add"
                    title="打开空间首页"
                    onClick={(e) => {
                      e.stopPropagation();
                      onOpen(s.homepageId!);
                    }}
                  >
                    <BookText size={13} />
                  </button>
                )}
                <button
                  className="tree-add"
                  title="在空间顶层新建页面"
                  onClick={(e) => {
                    e.stopPropagation();
                    onCreate(s.key, null);
                  }}
                >
                  <Plus size={13} />
                </button>
              </div>
              {open && <ul className="tree">{renderChildren(id, s, 1)}</ul>}
            </li>
          );
        })}
        {tree.spaces && visible.length === 0 && <li className="muted list-empty">没有匹配的空间</li>}
      </ul>
    </>
  );
}

// ---------- 搜索 ----------

const DAY_OPTIONS = [
  { days: 0, label: "不限时间" },
  { days: 7, label: "最近一周" },
  { days: 30, label: "最近一月" },
  { days: 365, label: "最近一年" },
];

function SearchPanel({ initial, spaces, selected, onOpen }: { initial?: string; spaces: WikiSpace[]; selected: string | null; onOpen: (id: string) => void }) {
  const menus = useMenus();
  const [text, setText] = useState(initial ?? "");
  const [space, setSpace] = useState("");
  const [days, setDays] = useState(0);
  const [mine, setMine] = useState(false);
  const [server, setServer] = useState(false);
  const [result, setResult] = useState<{ source: string; total: number; hits: WikiPageHit[] } | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (initial !== undefined) setText(initial);
  }, [initial]);

  useEffect(() => {
    const q = text.trim();
    if (!q && !space && !days && !mine) {
      setResult(null);
      return;
    }
    let alive = true;
    setLoading(true);
    const timer = setTimeout(() => {
      api.wikiSearch({ text: q, space, days, mine }, server).then(
        (r) => {
          if (!alive) return;
          setResult(r);
          setError(null);
          setLoading(false);
        },
        (e) => {
          if (!alive) return;
          setError(errorMessage(e));
          setLoading(false);
        },
      );
    }, 250);
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [text, space, days, mine, server]);

  const terms = text.trim().toLowerCase().split(/\s+/).filter(Boolean);

  return (
    <>
      <div className="list-toolbar wiki-subtoolbar">
        <div className="input-icon">
          {loading ? <Loader2 size={14} className="spin" /> : <Search size={14} />}
          <input autoFocus value={text} placeholder="搜索标题和正文" onChange={(e) => setText(e.target.value)} />
        </div>
        <div className="wiki-filters">
          <select value={space} onChange={(e) => setSpace(e.target.value)}>
            <option value="">全部空间</option>
            {spaces.map((s) => (
              <option key={s.key} value={s.key}>
                {s.name}
              </option>
            ))}
          </select>
          <select value={days} onChange={(e) => setDays(Number(e.target.value))}>
            {DAY_OPTIONS.map((o) => (
              <option key={o.days} value={o.days}>
                {o.label}
              </option>
            ))}
          </select>
          <label className="checkbox small">
            <input type="checkbox" checked={mine} onChange={(e) => setMine(e.target.checked)} />
            我修改的
          </label>
        </div>
        {result && (
          <div className="muted small list-meta">
            <span>
              {result.source === "local" ? `本机 Wiki 库 · ${result.hits.length} 个结果` : `Confluence 搜索 · 共 ${result.total} 个`}
            </span>
            <span className="spacer" />
            <button className="link small" onClick={() => setServer((v) => !v)}>
              {server ? "改用本机搜索" : "在服务器上搜索"}
            </button>
          </div>
        )}
      </div>
      {error && <ErrorBox message={error} />}
      <ul className="doc-list">
        {result?.hits.map((h) => (
          <li key={h.id}>
            <button className={itemClass("doc-item", selected === h.id, menus.target === h.id)} onClick={() => onOpen(h.id)} onContextMenu={(e) => menus.open(e, menus.wikiPage({ id: h.id, title: h.title, space: h.spaceName }), h.id)}>
              <span className="doc-item-title">
                <Highlight text={h.title} terms={terms} />
              </span>
              {h.snippet && (
                <span className="doc-item-excerpt muted small hit-snippet">
                  <Highlight text={h.snippet} terms={terms} />
                </span>
              )}
              <span className="muted small ellipsis">
                {h.spaceName}
                {h.ancestors.length > 0 && ` › ${h.ancestors[h.ancestors.length - 1].title}`}
                {h.authorName && ` · ${h.authorName}`}
                {h.modified && ` · ${formatTime(h.modified)}`}
              </span>
            </button>
          </li>
        ))}
        {result && result.hits.length === 0 && <li className="muted list-empty">没有找到页面</li>}
        {!result && !loading && <li className="muted list-empty">输入关键词搜索；多个关键词用空格分开，需全部出现</li>}
      </ul>
    </>
  );
}

/** 高亮关键词。 */
export function Highlight({ text, terms }: { text: string; terms: string[] }) {
  if (terms.length === 0) return <>{text}</>;
  const lower = text.toLowerCase();
  const parts: React.ReactNode[] = [];
  let i = 0;
  while (i < text.length) {
    let next = -1;
    let term = "";
    for (const t of terms) {
      const at = lower.indexOf(t, i);
      if (at >= 0 && (next < 0 || at < next)) {
        next = at;
        term = t;
      }
    }
    if (next < 0) {
      parts.push(text.slice(i));
      break;
    }
    if (next > i) parts.push(text.slice(i, next));
    parts.push(<mark key={next}>{text.slice(next, next + term.length)}</mark>);
    i = next + term.length;
  }
  return <>{parts}</>;
}
