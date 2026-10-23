import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { BookOpen, CheckSquare, ChevronRight, CircleDot, Copy, ExternalLink, FilePlus2, FileText, History, MoreHorizontal, NotepadText, Paperclip, Pencil, RefreshCw, Star } from "lucide-react";
import { api, errorMessage, type Attachment, type IssueSummary, type WikiNode, type WikiPageDetail } from "../../api";
import { AttachmentViewer } from "../../components/AttachmentViewer";
import { useContextMenu } from "../../components/ContextMenu";
import { ErrorBox, Skeleton, StatusPill, WebLoginHint } from "../../components/common";
import { RichHtml } from "../../components/RichHtml";
import { toast } from "../../components/Toast";
import { copyText } from "../../lib/clipboard";
import { formatSize, formatTime } from "../../lib/format";
import { fetchIssues, fillJiraMacros, headingsOf, issueKeysIn, refreshFavorite, toggleFavorite, useFavorites, type TocItem } from "../../lib/wiki";
import { workspaceChanged } from "../../lib/workspace";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { Backlinks } from "../workspace/Backlinks";
import { wikiToPage } from "../workspace/kbImport";
import { HistoryDialog } from "./HistoryDialog";
import { WikiComments } from "./WikiComments";

/** 目录至少有这么多标题时才显示。 */
const TOC_MIN = 3;

export function PageView(props: {
  pageId: string;
  anchor?: string;
  onOpen: (id: string) => void;
  onLoaded: (page: WikiPageDetail) => void;
  onEdit: () => void;
  onNewChild: () => void;
}) {
  const { pageId, onLoaded } = props;
  const { baseUrl } = useSettings();
  const { navigate } = useNav();
  const favorites = useFavorites();
  const [page, setPage] = useState<WikiPageDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [toc, setToc] = useState<TocItem[]>([]);
  const [issues, setIssues] = useState<{ keys: string[]; map: Map<string, IssueSummary> } | null>(null);
  const [history, setHistory] = useState(false);
  const menu = useContextMenu();

  // 只采用最近一次请求的结果：快速切换页面时，已离开的页面晚到的结果不能再把选中项改回去
  const requestId = useRef(0);
  const load = useCallback(async () => {
    const current = ++requestId.current;
    setError(null);
    try {
      const detail = await api.wikiPage(pageId);
      if (current !== requestId.current) return;
      setPage(detail);
      onLoaded(detail);
      refreshFavorite({ id: detail.id, title: detail.title, space: detail.spaceName });
    } catch (e) {
      if (current === requestId.current) setError(errorMessage(e));
    }
  }, [pageId, onLoaded]);

  useEffect(() => {
    void load();
    return () => {
      requestId.current++;
    };
  }, [load]);

  const jiraBase = baseUrl("jira");
  const jiraReady = Boolean(jiraBase);

  // 页面内容插入后：目录、Jira 宏的状态、任务勾选、跳到锚点
  const enhance = useCallback(
    (root: HTMLDivElement) => {
      if (!page) return;
      const headings = headingsOf(root);
      setToc(headings);
      // Confluence 的目录宏在网页端由脚本生成，这里直接填上
      root.querySelectorAll(".toc-macro").forEach((el) => {
        const list = document.createElement("ul");
        list.className = "wiki-inline-toc";
        headings.forEach((h) => {
          const li = document.createElement("li");
          li.style.paddingLeft = `${(h.level - 1) * 14}px`;
          const a = document.createElement("a");
          a.href = `#${h.id}`;
          a.textContent = h.text;
          li.appendChild(a);
          list.appendChild(li);
        });
        el.replaceChildren(list);
      });
      // 页面中的任务：可以直接勾选
      root.querySelectorAll<HTMLLIElement>("ul.inline-task-list > li[data-inline-task-id]").forEach((li) => {
        li.classList.add("wiki-task");
        li.title = "点击勾选或取消";
      });
      const keys = issueKeysIn(root, jiraBase);
      let alive = true;
      if (keys.length > 0 && jiraReady) {
        void fetchIssues(keys).then((map) => {
          if (!alive) return;
          fillJiraMacros(root, map);
          setIssues({ keys, map });
        });
      } else {
        setIssues({ keys, map: new Map() });
      }
      if (props.anchor) {
        const target = document.getElementById(props.anchor) ?? root.querySelector(`[name="${CSS.escape(props.anchor)}"]`);
        target?.scrollIntoView({ block: "start" });
      }
      return () => {
        alive = false;
      };
    },
    [page, jiraBase, jiraReady, props.anchor],
  );

  /** 点击任务的勾选框位置：勾选或取消（写入 Wiki）。 */
  const onClickCapture = (event: React.MouseEvent<HTMLDivElement>): boolean => {
    const li = (event.target as HTMLElement).closest<HTMLLIElement>("li.wiki-task");
    if (!li || !page || (event.target as HTMLElement).closest("a")) return false;
    // 只响应左侧勾选框区域，避免选中文字时误触
    const rect = li.getBoundingClientRect();
    if (event.clientX - rect.left > 24) return false;
    const taskId = li.dataset.inlineTaskId!;
    const done = !li.classList.contains("checked");
    li.classList.toggle("checked", done);
    api.wikiSetTask(page.id, taskId, done).then(
      () => toast(done ? "已完成任务" : "已取消完成"),
      (e) => {
        li.classList.toggle("checked", !done);
        toast(`修改任务失败：${errorMessage(e)}`, true);
      },
    );
    return true;
  };

  if (error) {
    return (
      <div className="detail-body">
        <ErrorBox message={error} onRetry={load} />
      </div>
    );
  }
  if (!page) {
    return (
      <div className="detail-body">
        <Skeleton lines={2} height={22} />
        <Skeleton lines={10} />
      </div>
    );
  }

  const favorite = favorites.some((f) => f.id === page.id);
  const copy = (text: string) =>
    copyText(text).then(
      () => toast("已复制"),
      (e) => toast(`复制失败：${errorMessage(e)}`, true),
    );
  const moreMenu = (e: React.MouseEvent) =>
    menu.open(e, [
      {
        label: "剪藏到知识库",
        icon: <BookOpen size={14} />,
        onSelect: () =>
          wikiToPage(page.id, baseUrl("confluence")).then(
            (doc) => navigate({ page: "kb", docId: doc.id }),
            (err) => toast(errorMessage(err), true),
          ),
      },
      {
        label: "写笔记",
        icon: <NotepadText size={14} />,
        onSelect: async () => {
          const doc = await api.wsSaveDoc({ kind: "note", title: page.title, content: `[${page.title}](${page.url})\n\n` });
          workspaceChanged();
          navigate({ page: "notes", docId: doc.id });
        },
      },
      {
        label: "添加待办",
        icon: <CheckSquare size={14} />,
        onSelect: async () => {
          await api.wsSaveTodo({ title: page.title, refSystem: "wiki", refKey: page.id, refTitle: page.title });
          workspaceChanged();
          toast("已添加待办");
        },
      },
      "separator",
      { label: "复制链接", icon: <Copy size={14} />, onSelect: () => void copy(page.url) },
      { label: "复制为 Markdown 链接", onSelect: () => void copy(`[${page.title}](${page.url})`) },
      { label: "刷新", icon: <RefreshCw size={14} />, onSelect: () => void load() },
      { label: "在浏览器中打开", icon: <ExternalLink size={14} />, onSelect: () => void openUrl(page.url) },
    ]);

  return (
    <div className={`wiki-layout${toc.length >= TOC_MIN ? " with-toc" : ""}`}>
      <div className="detail-body wiki-body">
        <header className="wiki-header">
          <div className="breadcrumbs muted small">
            <span>{page.spaceName}</span>
            {page.ancestors.map((a) => (
              <span key={a.id}>
                <ChevronRight size={12} />
                <button className="link" onClick={() => props.onOpen(a.id)}>
                  {a.title}
                </button>
              </span>
            ))}
          </div>
          <div className="wiki-title-row">
            <h1 className="wiki-title">
              {page.title}
              <button className={`star${favorite ? " on" : ""}`} title={favorite ? "取消收藏" : "收藏"} onClick={() => toggleFavorite({ id: page.id, title: page.title, space: page.spaceName })}>
                <Star size={16} fill={favorite ? "currentColor" : "none"} />
              </button>
            </h1>
            {page.canEdit && (
              <button className="btn" onClick={props.onEdit}>
                <Pencil size={14} />
                编辑
              </button>
            )}
            <button className="btn subtle icon" title="新建子页面" onClick={props.onNewChild}>
              <FilePlus2 size={15} />
            </button>
            <button className="btn subtle icon" title="历史版本" onClick={() => setHistory(true)}>
              <History size={15} />
            </button>
            <button className="btn subtle icon" title="更多" onClick={moreMenu}>
              <MoreHorizontal size={15} />
            </button>
          </div>
          <div className="muted small wiki-meta">
            <span>
              {page.modifiedBy} 修改于 {formatTime(page.modified)} · 第 {page.version} 版
            </span>
            {page.createdBy && (
              <span>
                · {page.createdBy} 创建于 {formatTime(page.created)}
              </span>
            )}
            {page.labels.map((l) => (
              <span key={l} className="tag-chip">
                {l}
              </span>
            ))}
          </div>
        </header>

        <WebLoginHint service="confluence" label="Wiki" />

        <RichHtml service="confluence" className="wiki-content" html={page.html} enhance={enhance} onClickCapture={onClickCapture} />

        {issues && issues.keys.length > 0 && <ReferencedIssues keys={issues.keys} map={issues.map} jiraReady={jiraReady} />}

        <ChildPages pageId={page.id} onOpen={props.onOpen} />

        <WikiAttachments pageId={page.id} />

        <Backlinks system="wiki" itemKey={page.id} title="工作空间" hideEmpty />

        <WikiComments pageId={page.id} />
      </div>
      {toc.length >= TOC_MIN && <TableOfContents items={toc} />}
      {history && <HistoryDialog page={page} onClose={() => setHistory(false)} />}
      {menu.menu}
    </div>
  );
}

function TableOfContents({ items }: { items: TocItem[] }) {
  const minLevel = Math.min(...items.map((i) => i.level));
  return (
    <nav className="wiki-toc">
      <div className="muted small wiki-toc-title">目录</div>
      <ul>
        {items.map((item) => (
          <li key={item.id} style={{ paddingLeft: (item.level - minLevel) * 12 }}>
            <a
              href={`#${item.id}`}
              onClick={(e) => {
                e.preventDefault();
                document.getElementById(item.id)?.scrollIntoView({ behavior: "smooth", block: "start" });
              }}
              title={item.text}
            >
              {item.text}
            </a>
          </li>
        ))}
      </ul>
    </nav>
  );
}

function ReferencedIssues({ keys, map, jiraReady }: { keys: string[]; map: Map<string, IssueSummary>; jiraReady: boolean }) {
  const { navigate } = useNav();
  return (
    <section className="block">
      <h2>
        <CircleDot size={16} className="muted" />
        引用的问题 <span className="count">{keys.length}</span>
      </h2>
      <ul className="links">
        {keys.map((key) => {
          const issue = map.get(key);
          return (
            <li key={key} className={jiraReady ? "clickable" : ""} onClick={() => jiraReady && navigate({ page: "jira", issueKey: key })}>
              <span className="issue-key">{key}</span>
              <span className="ellipsis grow">{issue?.summary ?? (jiraReady ? "无法获取（可能没有权限）" : "")}</span>
              {issue && <StatusPill status={issue.status} />}
            </li>
          );
        })}
      </ul>
    </section>
  );
}

function ChildPages({ pageId, onOpen }: { pageId: string; onOpen: (id: string) => void }) {
  const [children, setChildren] = useState<WikiNode[] | null>(null);
  useEffect(() => {
    api.wikiChildren(pageId).then(setChildren, () => setChildren([]));
  }, [pageId]);
  if (!children || children.length === 0) return null;
  return (
    <section className="block">
      <h2>
        <FileText size={16} className="muted" />
        子页面 <span className="count">{children.length}</span>
      </h2>
      <div className="child-pages">
        {children.map((c) => (
          <button key={c.id} className="child-page" onClick={() => onOpen(c.id)}>
            <FileText size={13} />
            {c.title}
          </button>
        ))}
      </div>
    </section>
  );
}

function WikiAttachments({ pageId }: { pageId: string }) {
  const [list, setList] = useState<Attachment[] | null>(null);
  const [viewing, setViewing] = useState<number | null>(null);
  useEffect(() => {
    api.wikiAttachments(pageId).then(setList, () => setList([]));
  }, [pageId]);
  const sorted = useMemo(() => [...(list ?? [])].sort((a, b) => b.created.localeCompare(a.created)), [list]);
  if (!list || list.length === 0) return null;
  return (
    <section className="block">
      <h2>
        <Paperclip size={16} className="muted" />
        附件 <span className="count">{list.length}</span>
      </h2>
      <ul className="links">
        {sorted.map((a, i) => (
          <li key={a.id} className="clickable" onClick={() => setViewing(i)} title="在应用内预览">
            <Paperclip size={13} className="muted" />
            <span className="ellipsis grow">{a.filename}</span>
            <span className="muted small nowrap">
              {formatSize(a.size)} · {a.author} · {formatTime(a.created)}
            </span>
          </li>
        ))}
      </ul>
      {viewing !== null && (
        <AttachmentViewer
          service="confluence"
          attachments={sorted}
          index={viewing}
          onClose={() => setViewing(null)}
          onOpenExternal={(a) => api.jiraOpenAttachment(a.contentUrl, a.filename, "confluence").catch((e) => toast(errorMessage(e), true))}
        />
      )}
    </section>
  );
}
