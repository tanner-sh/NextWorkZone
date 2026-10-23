import { useCallback, useEffect, useMemo, useState } from "react";
import { BookOpen, ChevronDown, ChevronRight, ChevronsDownUp, ChevronsUpDown, CircleDot, ExternalLink, FileInput, FolderInput, Plus, Search, Send, Tag } from "lucide-react";
import { api, errorMessage, type Doc, type DocSummary, type IssueChoice } from "../../api";
import { ErrorBox, Modal, Skeleton } from "../../components/common";
import { useContextMenu, type MenuEntry } from "../../components/ContextMenu";
import { useWorkspaceRefresh, workspaceChanged } from "../../lib/workspace";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { Picker } from "../jira/fieldForm";
import { DocPane } from "./DocPane";
import { copyTitleItem, deleteItem } from "./docMenu";
import { guarded } from "../../components/Toast";
import { markdownToStorage } from "./editor/convert";
import { issueToPage, reclipWikiPage, wikiToPage, wikiVersionOf } from "./kbImport";
import { formatTime } from "../../lib/format";
import { pageIdOf } from "../../lib/wiki";
import { WikiDiff } from "../wiki/HistoryDialog";

const EXPANDED_KEY = "nextworkzone.kb.expanded";

function loadExpanded(): string[] {
  try {
    return JSON.parse(localStorage.getItem(EXPANDED_KEY) ?? "[]");
  } catch {
    return [];
  }
}

/** 知识库：树状组织的页面，支持标签、从 Jira 沉淀、剪藏 Wiki、发布到 Wiki。 */
export function KnowledgePage() {
  const { current, navigate } = useNav();
  const { isReady } = useSettings();
  const contextMenu = useContextMenu();
  const [pageDialog, setPageDialog] = useState<{ kind: "move" | "publish"; doc: Doc } | null>(null);
  const [pages, setPages] = useState<DocSummary[] | null>(null);
  const [selected, setSelected] = useState<string | null>(current.docId ?? null);
  const [expanded, setExpanded] = useState<string[]>(loadExpanded);
  const [filter, setFilter] = useState("");
  const [tag, setTag] = useState<string | null>(null);
  const [dialog, setDialog] = useState<"jira" | "wiki" | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    try {
      setPages(await api.wsDocs("page"));
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, []);
  useEffect(() => {
    void load();
  }, [load]);
  useWorkspaceRefresh(load);

  useEffect(() => {
    if (current.page === "kb" && current.docId) setSelected(current.docId);
  }, [current]);

  useEffect(() => {
    try {
      localStorage.setItem(EXPANDED_KEY, JSON.stringify(expanded));
    } catch {
      // 不记忆
    }
  }, [expanded]);

  const byParent = useMemo(() => {
    const map = new Map<string | null, DocSummary[]>();
    const ids = new Set((pages ?? []).map((p) => p.id));
    for (const p of pages ?? []) {
      // 上级被删除的页面显示在顶层
      const parent = p.parentId && ids.has(p.parentId) ? p.parentId : null;
      map.set(parent, [...(map.get(parent) ?? []), p]);
    }
    for (const list of map.values()) list.sort((a, b) => a.sort - b.sort || a.title.localeCompare(b.title));
    return map;
  }, [pages]);

  // 选中的页面所在的上级都展开
  useEffect(() => {
    if (!selected || !pages) return;
    const chain: string[] = [];
    let cursor = pages.find((p) => p.id === selected)?.parentId ?? null;
    while (cursor) {
      chain.push(cursor);
      cursor = pages.find((p) => p.id === cursor)?.parentId ?? null;
    }
    if (chain.some((id) => !expanded.includes(id))) setExpanded((list) => [...new Set([...list, ...chain])]);
  }, [selected, pages]);

  const allTags = useMemo(() => [...new Set((pages ?? []).flatMap((p) => p.tags))].sort(), [pages]);
  const filtering = Boolean(filter.trim() || tag);
  const matches = useMemo(() => {
    const q = filter.trim().toLowerCase();
    return (pages ?? []).filter((p) => (!tag || p.tags.includes(tag)) && (!q || `${p.title} ${p.excerpt}`.toLowerCase().includes(q)));
  }, [pages, filter, tag]);

  const create = async (parentId: string | null) => {
    try {
      const doc = await api.wsSaveDoc({ kind: "page", title: "", content: "", parentId });
      workspaceChanged();
      if (parentId) setExpanded((list) => [...new Set([...list, parentId])]);
      await load();
      setSelected(doc.id);
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  /** 某个页面的所有下级页面 id。 */
  const descendants = (id: string): string[] => (byParent.get(id) ?? []).flatMap((c) => [c.id, ...descendants(c.id)]);

  const openPageDialog = (kind: "move" | "publish", id: string) =>
    guarded(async () => {
      const doc = await api.wsDoc(id);
      if (doc) setPageDialog({ kind, doc });
    })();

  const pageMenu = (page: DocSummary): MenuEntry[] => {
    const below = descendants(page.id);
    const allOpen = below.length > 0 && [page.id, ...below.filter((id) => (byParent.get(id) ?? []).length > 0)].every((id) => expanded.includes(id));
    return [
      { label: "添加子页面", icon: <Plus size={14} />, onSelect: () => create(page.id) },
      below.length > 0 && {
        label: allOpen ? "收起全部子页面" : "展开全部子页面",
        icon: allOpen ? <ChevronsDownUp size={14} /> : <ChevronsUpDown size={14} />,
        onSelect: () => setExpanded((list) => (allOpen ? list.filter((id) => id !== page.id && !below.includes(id)) : [...new Set([...list, page.id, ...below])])),
      },
      "separator",
      { label: "移动到…", icon: <FolderInput size={14} />, onSelect: () => openPageDialog("move", page.id) },
      isReady("confluence") && { label: "发布到 Wiki…", icon: <Send size={14} />, onSelect: () => openPageDialog("publish", page.id) },
      page.sourceSystem === "jira" && page.sourceKey && { label: `打开来源问题 ${page.sourceKey}`, icon: <CircleDot size={14} />, onSelect: () => navigate({ page: "jira", issueKey: page.sourceKey! }) },
      page.sourceSystem === "wiki" && page.sourceKey && { label: "打开 Wiki 原页面", icon: <ExternalLink size={14} />, onSelect: () => navigate({ page: "wiki", wikiPage: page.sourceKey! }) },
      copyTitleItem(page.title),
      "separator",
      deleteItem(page.id, below.length > 0 ? "删除（含子页面）" : "删除", () => setSelected((id) => (id && [page.id, ...below].includes(id) ? null : id))),
    ].filter(Boolean) as MenuEntry[];
  };

  const toggle = (id: string) => setExpanded((list) => (list.includes(id) ? list.filter((x) => x !== id) : [...list, id]));

  const renderTree = (parent: string | null, depth: number): React.ReactNode =>
    (byParent.get(parent) ?? []).map((page) => {
      const children = byParent.get(page.id) ?? [];
      const open = expanded.includes(page.id);
      return (
        <li key={page.id}>
          <div
            className={`tree-item${selected === page.id ? " selected" : ""}${contextMenu.target === page.id ? " menu-target" : ""}`}
            style={{ paddingLeft: 8 + depth * 16 }}
            onClick={() => setSelected(page.id)}
            onContextMenu={(e) => contextMenu.open(e, pageMenu(page), page.id)}
          >
            <button
              className="tree-toggle"
              onClick={(e) => {
                e.stopPropagation();
                toggle(page.id);
              }}
              style={{ visibility: children.length ? "visible" : "hidden" }}
              aria-label={open ? "收起" : "展开"}
            >
              {open ? <ChevronDown size={13} /> : <ChevronRight size={13} />}
            </button>
            <span className="ellipsis grow">{page.title || "无标题"}</span>
            {page.sourceSystem === "jira" && <CircleDot size={11} className="muted" />}
            <button
              className="tree-add"
              title="添加子页面"
              onClick={(e) => {
                e.stopPropagation();
                void create(page.id);
              }}
            >
              <Plus size={13} />
            </button>
          </div>
          {open && children.length > 0 && <ul className="tree">{renderTree(page.id, depth + 1)}</ul>}
        </li>
      );
    });

  return (
    <div className="split">
      <aside className="list-pane">
        <div className="list-toolbar">
          <div className="list-meta">
            <div className="input-icon">
              <Search size={14} />
              <input value={filter} placeholder="筛选页面" onChange={(e) => setFilter(e.target.value)} />
            </div>
            <button className="btn primary icon" title="新建页面" onClick={() => create(null)}>
              <Plus size={16} />
            </button>
          </div>
          <div className="list-meta">
            <button className="btn small-btn" onClick={() => setDialog("jira")}>
              <CircleDot size={13} />
              从 Jira 沉淀
            </button>
            <button className="btn small-btn" onClick={() => setDialog("wiki")}>
              <FileInput size={13} />
              剪藏 Wiki
            </button>
          </div>
          {allTags.length > 0 && (
            <div className="tag-filter">
              <Tag size={12} className="muted" />
              {allTags.map((t) => (
                <button key={t} className={`tag-chip${tag === t ? " active" : ""}`} onClick={() => setTag(tag === t ? null : t)}>
                  {t}
                </button>
              ))}
            </div>
          )}
        </div>
        {error && <ErrorBox message={error} onRetry={load} />}
        {filtering ? (
          <ul className="doc-list">
            {matches.map((p) => (
              <li key={p.id}>
                <button
                  className={`doc-item${selected === p.id ? " selected" : ""}${contextMenu.target === p.id ? " menu-target" : ""}`}
                  onClick={() => setSelected(p.id)}
                  onContextMenu={(e) => contextMenu.open(e, pageMenu(p), p.id)}
                >
                  <span className="doc-item-title">{p.title || "无标题"}</span>
                  {p.excerpt && <span className="doc-item-excerpt muted small">{p.excerpt}</span>}
                </button>
              </li>
            ))}
            {matches.length === 0 && <li className="muted list-empty">没有匹配的页面</li>}
          </ul>
        ) : (
          <ul className="tree root">
            {renderTree(null, 0)}
            {pages && pages.length === 0 && (
              <li className="muted list-empty">
                知识库还是空的。可以新建页面，或把解决过的 Jira 问题、常看的 Wiki 页面沉淀进来。
              </li>
            )}
          </ul>
        )}
      </aside>
      <section className="detail-pane">
        {selected ? (
          <DocPane
            key={selected}
            docId={selected}
            onSaved={(doc) => setPages((list) => list?.map((p) => (p.id === doc.id ? { ...p, title: doc.title, tags: doc.tags, updatedAt: doc.updatedAt } : p)) ?? list)}
            onDeleted={() => {
              setSelected(null);
              void load();
            }}
            header={(doc) => <PageHeader doc={doc} pages={pages ?? []} byParent={byParent} onSelect={setSelected} />}
            actions={(doc) => <PageActions doc={doc} pages={pages ?? []} onMoved={load} onAddChild={() => create(doc.id)} />}
          />
        ) : (
          <div className="empty-center">
            <BookOpen size={28} className="muted" />
            <div className="muted">选择左侧的页面，或新建一个</div>
          </div>
        )}
      </section>
      {contextMenu.menu}
      {pageDialog?.kind === "move" && (
        <MoveDialog
          doc={pageDialog.doc}
          pages={pages ?? []}
          onClose={() => setPageDialog(null)}
          onMoved={() => {
            setPageDialog(null);
            void load();
          }}
        />
      )}
      {pageDialog?.kind === "publish" && <PublishDialog doc={pageDialog.doc} onClose={() => setPageDialog(null)} />}
      {dialog && (
        <ImportDialog
          kind={dialog}
          parentId={selected && pages?.some((p) => p.id === selected) ? selected : null}
          onClose={() => setDialog(null)}
          onImported={async (doc) => {
            setDialog(null);
            await load();
            setSelected(doc.id);
          }}
        />
      )}
    </div>
  );
}

/** 面包屑、来源、子页面。 */
function PageHeader({ doc, pages, byParent, onSelect }: { doc: Doc; pages: DocSummary[]; byParent: Map<string | null, DocSummary[]>; onSelect: (id: string) => void }) {
  const { navigate } = useNav();
  const chain: DocSummary[] = [];
  let cursor = doc.parentId;
  while (cursor) {
    const parent = pages.find((p) => p.id === cursor);
    if (!parent) break;
    chain.unshift(parent);
    cursor = parent.parentId;
  }
  const children = byParent.get(doc.id) ?? [];
  return (
    <>
      {chain.length > 0 && (
        <div className="breadcrumbs muted small">
          {chain.map((p) => (
            <span key={p.id}>
              <button className="link" onClick={() => onSelect(p.id)}>
                {p.title || "无标题"}
              </button>
              <ChevronRight size={11} />
            </span>
          ))}
        </div>
      )}
      {doc.sourceSystem && (
        <div className="source-line muted small">
          {doc.sourceSystem === "jira" ? <CircleDot size={12} /> : <FileInput size={12} />}
          来源：
          {doc.sourceSystem === "jira" && doc.sourceKey ? (
            <button className="link" onClick={() => navigate({ page: "jira", issueKey: doc.sourceKey! })}>
              {doc.sourceKey}
            </button>
          ) : (
            doc.sourceKey && (
              <button className="link" onClick={() => navigate({ page: "wiki", wikiPage: doc.sourceKey! })}>
                Wiki 原页面{wikiVersionOf(doc.sourceUrl) ? `（第 ${wikiVersionOf(doc.sourceUrl)} 版）` : ""}
              </button>
            )
          )}
        </div>
      )}
      {doc.sourceSystem === "wiki" && doc.sourceKey && <ClipStatus doc={doc} />}
      {doc.publishedUrl && (
        <div className="source-line muted small">
          <Send size={12} />
          已发布到
          <button className="link" onClick={() => navigate({ page: "wiki", wikiPage: pageIdOf(doc.publishedUrl)! })}>
            Wiki 页面{wikiVersionOf(doc.publishedUrl) ? `（发布时为第 ${wikiVersionOf(doc.publishedUrl)} 版）` : ""}
          </button>
        </div>
      )}
      {children.length > 0 && (
        <div className="child-pages">
          {children.map((c) => (
            <button key={c.id} className="child-page" onClick={() => onSelect(c.id)}>
              <BookOpen size={13} />
              {c.title || "无标题"}
            </button>
          ))}
        </div>
      )}
    </>
  );
}

/** 剪藏的 Wiki 页面之后有更新时提示：查看变化、重新剪藏。 */
function ClipStatus({ doc }: { doc: Doc }) {
  const { baseUrl } = useSettings();
  const clipped = wikiVersionOf(doc.sourceUrl);
  const [latest, setLatest] = useState<{ version: number; by: string; when: string } | null>(null);
  const [dialog, setDialog] = useState<"diff" | "reclip" | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!clipped) return;
    let alive = true;
    api.wikiPageVersion(doc.sourceKey!).then((v) => alive && setLatest(v), () => {});
    return () => {
      alive = false;
    };
  }, [doc.sourceKey, clipped]);
  if (!clipped || !latest || latest.version <= clipped) return null;
  const reclip = async () => {
    setBusy(true);
    setError(null);
    try {
      await reclipWikiPage(doc, baseUrl("confluence"));
      setDialog(null);
      setLatest(null);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="notice info">
      <FileInput size={14} />
      <span className="grow">
        Wiki 原页面已更新到第 {latest.version} 版（{latest.by}，{formatTime(latest.when)}），这里剪藏的是第 {clipped} 版。
      </span>
      <button className="btn small-btn" onClick={() => setDialog("diff")}>
        查看变化
      </button>
      <button className="btn small-btn" onClick={() => setDialog("reclip")}>
        重新剪藏
      </button>
      {dialog === "diff" && (
        <Modal title={`原页面的变化（第 ${clipped} 版 → 第 ${latest.version} 版）`} wide onClose={() => setDialog(null)}>
          <ClipDiff pageId={doc.sourceKey!} from={clipped} to={latest.version} />
        </Modal>
      )}
      {dialog === "reclip" && (
        <Modal
          title="重新剪藏"
          onClose={() => setDialog(null)}
          footer={
            <>
              <button className="btn" onClick={() => setDialog(null)}>
                取消
              </button>
              <button className="btn primary" disabled={busy} onClick={reclip}>
                {busy ? "剪藏中…" : "用最新内容替换"}
              </button>
            </>
          }
        >
          <p>用 Wiki 原页面的最新内容替换这篇知识库页面的正文。你在这里做过的修改会被替换掉（可以先复制保留）。</p>
          {error && <ErrorBox message={error} />}
        </Modal>
      )}
    </div>
  );
}

function ClipDiff({ pageId, from, to }: { pageId: string; from: number; to: number }) {
  const [diff, setDiff] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    api.wikiDiff(pageId, from, to).then(setDiff, (e) => setError(errorMessage(e)));
  }, [pageId, from, to]);
  if (error) return <ErrorBox message={error} />;
  return diff === null ? <Skeleton lines={6} /> : <WikiDiff diff={diff} />;
}

function PageActions({ doc, pages, onMoved, onAddChild }: { doc: Doc; pages: DocSummary[]; onMoved: () => void; onAddChild: () => void }) {
  const { isReady } = useSettings();
  const [dialog, setDialog] = useState<"move" | "publish" | null>(null);
  return (
    <>
      <button className="btn subtle icon" title="添加子页面" onClick={onAddChild}>
        <Plus size={15} />
      </button>
      <button className="btn subtle icon" title="移动到…" onClick={() => setDialog("move")}>
        <FolderInput size={15} />
      </button>
      {isReady("confluence") && (
        <button className="btn subtle icon" title="发布到 Wiki" onClick={() => setDialog("publish")}>
          <Send size={15} />
        </button>
      )}
      {dialog === "move" && (
        <MoveDialog
          doc={doc}
          pages={pages}
          onClose={() => setDialog(null)}
          onMoved={() => {
            setDialog(null);
            onMoved();
          }}
        />
      )}
      {dialog === "publish" && <PublishDialog doc={doc} onClose={() => setDialog(null)} />}
    </>
  );
}

function MoveDialog({ doc, pages, onClose, onMoved }: { doc: Doc; pages: DocSummary[]; onClose: () => void; onMoved: () => void }) {
  const [target, setTarget] = useState<DocSummary | null>(null);
  const [error, setError] = useState<string | null>(null);
  // 不能移到自己或自己的下级
  const blocked = new Set<string>([doc.id]);
  let grew = true;
  while (grew) {
    grew = false;
    for (const p of pages) {
      if (p.parentId && blocked.has(p.parentId) && !blocked.has(p.id)) {
        blocked.add(p.id);
        grew = true;
      }
    }
  }
  const move = async (parentId: string | null) => {
    try {
      const siblings = pages.filter((p) => p.parentId === parentId && p.id !== doc.id);
      await api.wsMoveDoc(doc.id, parentId, Math.max(0, ...siblings.map((p) => p.sort)) + 1);
      workspaceChanged();
      onMoved();
    } catch (e) {
      setError(errorMessage(e));
    }
  };
  return (
    <Modal
      title={`移动“${doc.title || "无标题"}”`}
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={() => move(null)} disabled={doc.parentId === null}>
            移到顶层
          </button>
          <span className="spacer" />
          <button className="btn" onClick={onClose}>
            取消
          </button>
          <button className="btn primary" disabled={!target} onClick={() => target && move(target.id)}>
            移动
          </button>
        </>
      }
    >
      <div className="form-field">
        <span>移到哪个页面下</span>
        <Picker<DocSummary>
          selected={target ? [target] : []}
          onChange={(list) => setTarget(list[0] ?? null)}
          search={(q) => pages.filter((p) => !blocked.has(p.id) && (p.title || "无标题").toLowerCase().includes(q.trim().toLowerCase()))}
          label={(p) => p.title || "无标题"}
          id={(p) => p.id}
          placeholder="搜索页面"
          searchOnFocus
        />
      </div>
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}

function PublishDialog({ doc, onClose }: { doc: Doc; onClose: () => void }) {
  const { navigate } = useNav();
  const publishedId = pageIdOf(doc.publishedUrl);
  const publishedVersion = wikiVersionOf(doc.publishedUrl);
  /** 已发布过时默认更新原页面，也可以另外新建 */
  const [mode, setMode] = useState<"update" | "create">(publishedId ? "update" : "create");
  const [parent, setParent] = useState<{ id: string; title: string } | null>(null);
  const [title, setTitle] = useState(doc.title);
  const [publishing, setPublishing] = useState(false);
  const [published, setPublished] = useState<{ url: string; updated: boolean } | null>(null);
  const [error, setError] = useState<string | null>(null);
  /** 页面在上次发布之后被别人改过 */
  const [conflict, setConflict] = useState<{ version: number; by: string } | null>(null);

  useEffect(() => {
    if (!publishedId || !publishedVersion) return;
    api.wikiPageVersion(publishedId).then((v) => setConflict(v.version > publishedVersion ? { version: v.version, by: v.by } : null), () => {});
  }, [publishedId, publishedVersion]);

  const publish = async (overwrite = false) => {
    if (!title.trim() || (mode === "create" && !parent)) return;
    setPublishing(true);
    setError(null);
    try {
      const { storage, assets } = markdownToStorage(doc.content);
      const result = await api.wsPublishToWiki(doc.id, mode === "create" ? "create" : overwrite ? "overwrite" : "update", parent?.id ?? "", title.trim(), storage, assets);
      setPublished(result);
      workspaceChanged();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setPublishing(false);
    }
  };

  return (
    <Modal
      title="发布到 Wiki"
      onClose={onClose}
      dirty={publishing}
      footer={
        published ? (
          <>
            <button
              className="btn"
              onClick={() => {
                const id = pageIdOf(published.url);
                if (id) navigate({ page: "wiki", wikiPage: id });
                onClose();
              }}
            >
              打开页面
            </button>
            <button className="btn primary" onClick={onClose}>
              完成
            </button>
          </>
        ) : (
          <>
            <button className="btn" onClick={onClose}>
              取消
            </button>
            {mode === "update" && conflict ? (
              <button className="btn danger" disabled={!title.trim() || publishing} onClick={() => void publish(true)}>
                {publishing ? "发布中…" : "仍然覆盖"}
              </button>
            ) : (
              <button className="btn primary" disabled={(mode === "create" && !parent) || !title.trim() || publishing} onClick={() => void publish()}>
                {publishing ? "发布中…" : mode === "update" ? "更新页面" : "发布"}
              </button>
            )}
          </>
        )
      }
    >
      {published ? (
        <div className="notice ok">{published.updated ? "已更新 Wiki 页面" : "已发布为 Wiki 新页面"}，正文中的图片已作为附件上传。</div>
      ) : (
        <>
          {publishedId && (
            <div className="segmented small-seg">
              <button className={mode === "update" ? "active" : ""} onClick={() => setMode("update")}>
                更新已发布的页面
              </button>
              <button className={mode === "create" ? "active" : ""} onClick={() => setMode("create")}>
                另外新建页面
              </button>
            </div>
          )}
          {mode === "update" ? (
            <>
              <p className="muted small">用这篇知识库页面的当前内容更新上次发布的 Wiki 页面（其他人可见）。</p>
              {conflict && (
                <div className="notice warn">
                  这个 Wiki 页面在你上次发布后被修改过（现在是第 {conflict.version} 版，最后由 {conflict.by} 修改）。更新会覆盖这些修改；建议先到 Wiki 中查看历史版本。
                </div>
              )}
            </>
          ) : (
            <p className="muted small">会在所选页面下新建一个子页面（其他人可见），不会修改已有页面。工作空间内部的文档链接发布后只保留文字。</p>
          )}
          <label className="form-field">
            <span>页面标题</span>
            <input value={title} onChange={(e) => setTitle(e.target.value)} />
          </label>
          {mode === "create" && (
            <div className="form-field">
              <span>上级页面</span>
              <Picker<{ id: string; title: string; space?: string }>
                selected={parent ? [parent] : []}
                onChange={(list) => setParent(list[0] ?? null)}
                search={async (q) => {
                  const text = q.trim();
                  if (!text) return [];
                  // 直接粘贴页面地址
                  if (/^https?:\/\//.test(text) || /^\d+$/.test(text)) return [{ id: text, title: text }];
                  const results = await api.wikiSearch({ text, limit: 20 });
                  return results.hits.map((p) => ({ id: p.id, title: p.title, space: p.spaceName }));
                }}
                label={(p) => p.title}
                detail={(p) => p.space ?? ""}
                id={(p) => p.id}
                placeholder="搜索 Wiki 页面，或粘贴页面地址"
              />
            </div>
          )}
        </>
      )}
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}

function ImportDialog({ kind, parentId, onClose, onImported }: { kind: "jira" | "wiki"; parentId: string | null; onClose: () => void; onImported: (doc: Doc) => void }) {
  const { baseUrl, isReady } = useSettings();
  const [issue, setIssue] = useState<IssueChoice | null>(null);
  const [page, setPage] = useState<{ id: string; title: string } | null>(null);
  const [under, setUnder] = useState(Boolean(parentId));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const ready = kind === "jira" ? isReady("jira") : isReady("confluence");

  const run = async () => {
    setBusy(true);
    setError(null);
    try {
      const parent = under ? parentId : null;
      const doc = kind === "jira" ? await issueToPage(issue!.key, baseUrl("jira"), parent) : await wikiToPage(page!.id, baseUrl("confluence"), parent);
      onImported(doc);
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };

  return (
    <Modal
      title={kind === "jira" ? "从 Jira 问题沉淀" : "剪藏 Wiki 页面"}
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            取消
          </button>
          <button className="btn primary" disabled={busy || !ready || (kind === "jira" ? !issue : !page)} onClick={run}>
            {busy ? "处理中…" : kind === "jira" ? "沉淀为页面" : "剪藏"}
          </button>
        </>
      }
    >
      {!ready && <ErrorBox message={`尚未配置 ${kind === "jira" ? "Jira" : "Wiki"}`} />}
      <p className="muted small">
        {kind === "jira" ? "把问题的描述、解决方案等字段和讨论记录整理成一篇知识库页面，并保留与问题的关联。" : "把 Wiki 页面的当前内容保存为知识库页面（之后与原页面独立），可离线查看和修改。"}
      </p>
      {kind === "jira" ? (
        <div className="form-field">
          <span>问题</span>
          <Picker<IssueChoice>
            selected={issue ? [issue] : []}
            onChange={(list) => setIssue(list[0] ?? null)}
            search={async (q) => (q.trim() ? (await api.jiraPickIssues(q, null, false)).map((i) => ({ key: i.key, summary: i.summary })) : [])}
            label={(c) => `${c.key} ${c.summary}`}
            id={(c) => c.key}
            placeholder="输入问题键或概要搜索"
          />
        </div>
      ) : (
        <div className="form-field">
          <span>Wiki 页面</span>
          <Picker<{ id: string; title: string; space?: string }>
            selected={page ? [page] : []}
            onChange={(list) => setPage(list[0] ?? null)}
            search={async (q) => {
              const text = q.trim();
              if (!text) return [];
              if (/^https?:\/\//.test(text) || /^\d+$/.test(text)) return [{ id: text, title: text }];
              return (await api.globalSearch(text)).pages.map((p) => ({ id: p.id, title: p.title, space: p.space }));
            }}
            label={(p) => p.title}
            detail={(p) => p.space ?? ""}
            id={(p) => p.id}
            placeholder="搜索 Wiki 页面，或粘贴页面地址"
          />
        </div>
      )}
      {parentId && (
        <label className="checkbox">
          <input type="checkbox" checked={under} onChange={(e) => setUnder(e.target.checked)} />
          放在当前选中的页面下
        </label>
      )}
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}
