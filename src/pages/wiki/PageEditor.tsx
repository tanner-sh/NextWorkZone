import { useEffect, useRef, useState, type ReactNode } from "react";
import DOMPurify from "dompurify";
import { Bold, Code, Heading1, Heading2, Heading3, Italic, Link2, List, ListOrdered, Minus, Pilcrow, Quote, Redo2, Save, Strikethrough, Table, Underline, Undo2, X } from "lucide-react";
import { api, errorMessage, type WikiEditSession, type WikiSavePreview } from "../../api";
import { ErrorBox, Modal, Skeleton } from "../../components/common";
import { toast } from "../../components/Toast";
import { assetUrl } from "../../lib/asset";
import { fetchIssues } from "../../lib/wiki";
import { usePageActive } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { WikiDiff } from "./HistoryDialog";
import type { NewPageRequest } from "./NewPageDialog";

type Target = { kind: "edit"; pageId: string } | { kind: "new"; request: NewPageRequest };

interface Draft {
  title: string;
  html: string;
  /** 草稿基于的页面版本 */
  version: number;
  savedAt: number;
}

const DRAFT_PREFIX = "nextworkzone.wiki.draft.";
const FORMAT_KEYS: Record<string, string> = { b: "bold", i: "italic", u: "underline" };

function draftKey(target: Target): string {
  return DRAFT_PREFIX + (target.kind === "edit" ? target.pageId : `new:${target.request.space}:${target.request.parent ?? ""}`);
}

function readDraft(key: string): Draft | null {
  try {
    const raw = localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as Draft) : null;
  } catch {
    return null;
  }
}

function writeDraft(key: string, draft: Draft | null) {
  try {
    if (draft) localStorage.setItem(key, JSON.stringify(draft));
    else localStorage.removeItem(key);
  } catch {
    // 不保存草稿
  }
}

/**
 * 编辑器内容序列化为 XHTML：宏等占位块换成 `<!--nwz:N-->`，布局容器换成首尾两个标记，
 * 由 Rust 换回原文后保存。
 */
function serialize(editor: HTMLElement): string {
  const root = editor.cloneNode(true) as HTMLElement;
  root.querySelectorAll<HTMLElement>("[data-nwz]").forEach((el) => el.replaceWith(document.createComment(`nwz:${el.dataset.nwz}`)));
  root.querySelectorAll<HTMLElement>(".nwz-container").forEach((el) => {
    const parent = el.parentNode!;
    parent.insertBefore(document.createComment(`nwz:${el.dataset.nwzOpen}`), el);
    while (el.firstChild) parent.insertBefore(el.firstChild, el);
    parent.insertBefore(document.createComment(`nwz:${el.dataset.nwzClose}`), el);
    el.remove();
  });
  const serializer = new XMLSerializer();
  return Array.from(root.childNodes)
    .map((n) => serializer.serializeToString(n))
    .join("")
    .replace(/ xmlns="http:\/\/www\.w3\.org\/1999\/xhtml"/g, "");
}

/**
 * Wiki 页面编辑器：普通内容（段落、标题、列表、表格、文字格式）可视化编辑；
 * 宏、图片、页面链接、任务列表等显示为不可编辑的块，保存时原样保留。
 * 自动保存草稿；保存前显示改动，页面在编辑期间被别人改过时不覆盖。
 */
export function PageEditor({ target, onClose, onSaved }: { target: Target; onClose: () => void; onSaved: (pageId: string) => void }) {
  const { sessionVersion } = useSettings();
  const [session, setSession] = useState<WikiEditSession | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [title, setTitle] = useState("");
  const [dirty, setDirty] = useState(false);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [preview, setPreview] = useState<{ xhtml: string; result: WikiSavePreview } | null>(null);
  const [checking, setChecking] = useState(false);
  const [confirmClose, setConfirmClose] = useState(false);
  const [linkOpen, setLinkOpen] = useState(false);
  const editorRef = useRef<HTMLDivElement>(null);
  const savedRange = useRef<Range | null>(null);
  const draftTimer = useRef<number | null>(null);
  const key = draftKey(target);
  const pageId = target.kind === "edit" ? target.pageId : null;

  useEffect(() => {
    let alive = true;
    const load = target.kind === "edit" ? api.wikiEdit(target.pageId) : api.wikiNewPage(target.request.space, target.request.template, target.request.storage);
    load.then(
      (s) => {
        if (!alive) return;
        setSession(s);
        setTitle(target.kind === "new" ? target.request.title : s.title);
        const saved = readDraft(key);
        // 草稿基于的版本与当前一致时才能恢复，否则会覆盖别人的修改
        if (saved && saved.version === s.version) setDraft(saved);
      },
      (e) => alive && setError(errorMessage(e)),
    );
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // 内容放进编辑器后，补上图片、用户名、问题状态等显示
  const fill = (html: string) => {
    const editor = editorRef.current;
    if (!editor || !session) return;
    editor.innerHTML = DOMPurify.sanitize(html, { ADD_ATTR: ["contenteditable", "data-nwz", "data-nwz-open", "data-nwz-close", "data-nwz-attachment", "data-nwz-url", "data-nwz-user", "data-jira-key"] }) || "<p><br></p>";
    editor.querySelectorAll<HTMLImageElement>("img[data-nwz-attachment]").forEach((img) => {
      if (pageId) img.src = assetUrl("confluence", `/download/attachments/${pageId}/${encodeURIComponent(img.dataset.nwzAttachment!)}`, sessionVersion);
    });
    editor.querySelectorAll<HTMLImageElement>("img[data-nwz-url]").forEach((img) => {
      if (/^https?:/.test(img.dataset.nwzUrl ?? "")) img.src = img.dataset.nwzUrl!;
    });
    if (session.users.length > 0) {
      api.wikiUsers(session.users).then((names) => {
        editor.querySelectorAll<HTMLElement>("[data-nwz-user]").forEach((el) => {
          const name = names[el.dataset.nwzUser!];
          if (name) el.textContent = `@${name}`;
        });
      }, () => {});
    }
    const keys = [...new Set(Array.from(editor.querySelectorAll<HTMLElement>(".nwz-jira[data-jira-key]")).map((el) => el.dataset.jiraKey!))];
    if (keys.length > 0) {
      void fetchIssues(keys).then((map) => {
        editor.querySelectorAll<HTMLElement>(".nwz-jira[data-jira-key]").forEach((el) => {
          const issue = map.get(el.dataset.jiraKey!);
          if (issue) el.textContent = `${issue.key} ${issue.summary} · ${issue.status.name}`;
        });
      });
    }
  };

  useEffect(() => {
    if (session) fill(session.html);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session]);

  const changed = () => {
    setDirty(true);
    if (draftTimer.current) window.clearTimeout(draftTimer.current);
    draftTimer.current = window.setTimeout(() => {
      draftTimer.current = null;
      if (editorRef.current && session) writeDraft(key, { title, html: editorRef.current.innerHTML, version: session.version, savedAt: Date.now() });
    }, 800);
  };

  useEffect(() => {
    if (session && dirty) changed();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [title]);

  useEffect(
    () => () => {
      if (draftTimer.current) window.clearTimeout(draftTimer.current);
    },
    [],
  );

  // ---------- 编辑命令 ----------

  const rememberSelection = () => {
    const sel = window.getSelection();
    if (sel && sel.rangeCount > 0 && editorRef.current?.contains(sel.anchorNode)) savedRange.current = sel.getRangeAt(0).cloneRange();
  };

  const restoreSelection = () => {
    const range = savedRange.current;
    if (!range) return;
    const sel = window.getSelection();
    sel?.removeAllRanges();
    sel?.addRange(range);
  };

  const exec = (command: string, arg?: string) => {
    if (!editorRef.current?.contains(document.activeElement)) restoreSelection();
    editorRef.current?.focus();
    document.execCommand(command, false, arg);
    changed();
  };

  const wrapInline = (tag: string) => {
    if (!editorRef.current?.contains(document.activeElement)) restoreSelection();
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return;
    const range = sel.getRangeAt(0);
    const el = document.createElement(tag);
    el.appendChild(range.extractContents());
    range.insertNode(el);
    sel.removeAllRanges();
    changed();
  };

  const insertTable = () => {
    const cells = (tag: string) => Array.from({ length: 3 }, () => `<${tag}><p><br></p></${tag}>`).join("");
    exec("insertHTML", `<table><tbody><tr>${cells("th")}</tr><tr>${cells("td")}</tr><tr>${cells("td")}</tr></tbody></table><p><br></p>`);
  };

  const onKeyDown = (e: React.KeyboardEvent<HTMLDivElement>) => {
    if (!e.ctrlKey) return;
    const format = FORMAT_KEYS[e.key.toLowerCase()];
    if (format && !e.shiftKey && !e.altKey) {
      e.preventDefault();
      exec(format);
    }
  };

  const onPaste = (e: React.ClipboardEvent<HTMLDivElement>) => {
    if (Array.from(e.clipboardData.files).some((f) => f.type.startsWith("image/"))) {
      e.preventDefault();
      toast("暂不支持在 Wiki 编辑器中粘贴图片，请在网页上传附件后插入", true);
      return;
    }
    const html = e.clipboardData.getData("text/html");
    if (html) {
      e.preventDefault();
      // 只保留结构和基本格式，去掉网页、Office 带来的样式和脚本
      const clean = DOMPurify.sanitize(html, {
        ALLOWED_TAGS: ["p", "br", "b", "strong", "i", "em", "u", "s", "del", "sup", "sub", "code", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "thead", "tbody", "tr", "th", "td", "a", "blockquote", "hr"],
        ALLOWED_ATTR: ["href", "colspan", "rowspan"],
      });
      document.execCommand("insertHTML", false, clean);
      changed();
    }
  };

  // Ctrl+S 保存（切到其他页面时不响应）
  const active = usePageActive();
  useEffect(() => {
    if (!active) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.ctrlKey && e.key.toLowerCase() === "s") {
        e.preventDefault();
        void review();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  // ---------- 保存 ----------

  const review = async () => {
    if (!editorRef.current || !session || checking) return;
    setChecking(true);
    setError(null);
    try {
      const xhtml = serialize(editorRef.current);
      const result = await api.wikiPreviewSave(pageId, xhtml, session.fragments);
      setPreview({ xhtml, result });
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setChecking(false);
    }
  };

  const close = () => {
    if (dirty) setConfirmClose(true);
    else onClose();
  };

  if (error && !session) {
    return (
      <div className="detail-body">
        <ErrorBox message={error} />
        <div>
          <button className="btn" onClick={onClose}>
            返回
          </button>
        </div>
      </div>
    );
  }

  const tools: { icon: ReactNode; title: string; run: () => void }[] = [
    { icon: <Undo2 size={15} />, title: "撤销（Ctrl+Z）", run: () => exec("undo") },
    { icon: <Redo2 size={15} />, title: "重做（Ctrl+Shift+Z）", run: () => exec("redo") },
    { icon: <Pilcrow size={15} />, title: "正文", run: () => exec("formatBlock", "<p>") },
    { icon: <Heading1 size={15} />, title: "一级标题", run: () => exec("formatBlock", "<h1>") },
    { icon: <Heading2 size={15} />, title: "二级标题", run: () => exec("formatBlock", "<h2>") },
    { icon: <Heading3 size={15} />, title: "三级标题", run: () => exec("formatBlock", "<h3>") },
    { icon: <Bold size={15} />, title: "粗体（Ctrl+B）", run: () => exec("bold") },
    { icon: <Italic size={15} />, title: "斜体（Ctrl+I）", run: () => exec("italic") },
    { icon: <Underline size={15} />, title: "下划线（Ctrl+U）", run: () => exec("underline") },
    { icon: <Strikethrough size={15} />, title: "删除线", run: () => exec("strikeThrough") },
    { icon: <Code size={15} />, title: "行内代码", run: () => wrapInline("code") },
    { icon: <List size={15} />, title: "无序列表", run: () => exec("insertUnorderedList") },
    { icon: <ListOrdered size={15} />, title: "有序列表", run: () => exec("insertOrderedList") },
    { icon: <Quote size={15} />, title: "引用", run: () => exec("formatBlock", "<blockquote>") },
    { icon: <Table size={15} />, title: "插入表格", run: insertTable },
    { icon: <Minus size={15} />, title: "分隔线", run: () => exec("insertHorizontalRule") },
  ];

  return (
    <div className="detail-body wiki-editor-page">
      <header className="wiki-editor-head">
        <input className="wiki-title-input" value={title} placeholder="页面标题" onChange={(e) => setTitle(e.target.value)} />
        <span className="muted small nowrap">{target.kind === "edit" ? (session ? `基于第 ${session.version} 版编辑` : "") : "新页面"}{dirty && " · 已自动保存草稿"}</span>
        <button className="btn subtle" onClick={close}>
          <X size={14} />
          取消
        </button>
        <button className="btn primary" disabled={!session || checking} onClick={() => void review()} title="Ctrl+S">
          <Save size={14} />
          {checking ? "检查中…" : target.kind === "edit" ? "保存…" : "创建…"}
        </button>
      </header>
      {draft && (
        <div className="notice warn">
          <span className="grow">有一份 {new Date(draft.savedAt).toLocaleString()} 未保存的草稿。</span>
          <button
            className="btn"
            onClick={() => {
              fill(draft.html);
              setTitle(draft.title);
              setDraft(null);
              setDirty(true);
            }}
          >
            恢复草稿
          </button>
          <button
            className="btn subtle"
            onClick={() => {
              writeDraft(key, null);
              setDraft(null);
            }}
          >
            丢弃
          </button>
        </div>
      )}
      {error && <ErrorBox message={error} />}
      <div className="wiki-editor">
        <div className="wiki-toolbar" onMouseDown={(e) => e.preventDefault()}>
          {tools.map((t) => (
            <button key={t.title} className="btn subtle icon" title={t.title} onClick={t.run}>
              {t.icon}
            </button>
          ))}
          <span className="wiki-toolbar-link">
            <button
              className="btn subtle icon"
              title="链接"
              onClick={() => {
                rememberSelection();
                setLinkOpen((v) => !v);
              }}
            >
              <Link2 size={15} />
            </button>
            {linkOpen && (
              <LinkPopover
                onClose={() => setLinkOpen(false)}
                onInsert={(url) => {
                  setLinkOpen(false);
                  restoreSelection();
                  const sel = window.getSelection();
                  if (sel && !sel.isCollapsed) exec("createLink", url);
                  else exec("insertHTML", `<a href="${url.replace(/"/g, "&quot;")}">${url.replace(/</g, "&lt;")}</a>`);
                }}
              />
            )}
          </span>
        </div>
        {!session && <Skeleton lines={10} />}
        <div
          ref={editorRef}
          className="rich wiki-content wiki-editable"
          contentEditable={Boolean(session)}
          suppressContentEditableWarning
          onInput={changed}
          onKeyDown={onKeyDown}
          onKeyUp={rememberSelection}
          onMouseUp={rememberSelection}
          onPaste={onPaste}
          style={session ? undefined : { display: "none" }}
        />
      </div>
      <p className="muted small">灰色的块是宏、图片、页面链接、任务等暂不支持在这里编辑的内容，保存时原样保留；可以在网页上编辑它们。</p>

      {preview && session && (
        <SaveDialog
          target={target}
          session={session}
          title={title}
          xhtml={preview.xhtml}
          result={preview.result}
          onClose={() => setPreview(null)}
          onSaved={(id) => {
            writeDraft(key, null);
            setPreview(null);
            setDirty(false);
            onSaved(id);
          }}
        />
      )}
      {confirmClose && (
        <Modal
          title="放弃编辑？"
          onClose={() => setConfirmClose(false)}
          footer={
            <>
              <button className="btn" onClick={() => setConfirmClose(false)}>
                继续编辑
              </button>
              <button className="btn" onClick={onClose}>
                保留草稿并退出
              </button>
              <button
                className="btn danger"
                onClick={() => {
                  writeDraft(key, null);
                  onClose();
                }}
              >
                丢弃修改
              </button>
            </>
          }
        >
          <p>修改尚未保存到 Wiki。草稿保留在本机，下次编辑同一页面（且页面没有被别人修改）时可以恢复。</p>
        </Modal>
      )}
    </div>
  );
}

function LinkPopover({ onInsert, onClose }: { onInsert: (url: string) => void; onClose: () => void }) {
  const [url, setUrl] = useState("");
  return (
    <div className="wiki-link-popover" onMouseDown={(e) => e.stopPropagation()}>
      <input
        autoFocus
        value={url}
        placeholder="粘贴链接地址，回车插入"
        onChange={(e) => setUrl(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && url.trim()) {
            e.preventDefault();
            onInsert(url.trim());
          } else if (e.key === "Escape") {
            onClose();
          }
        }}
      />
    </div>
  );
}

/** 保存前确认：显示改动、填写修改说明，选择是否为小修改（不通知关注者）。 */
function SaveDialog(props: { target: Target; session: WikiEditSession; title: string; xhtml: string; result: WikiSavePreview; onClose: () => void; onSaved: (pageId: string) => void }) {
  const { target, session, title, xhtml, result } = props;
  const [message, setMessage] = useState("");
  const [minor, setMinor] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const titleChanged = target.kind === "edit" && title.trim() !== session.title;
  const nothing = target.kind === "edit" && !result.changed && !titleChanged;

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      if (target.kind === "edit") {
        await api.wikiSave({ page: target.pageId, title, xhtml, fragments: session.fragments, baseVersion: session.version, minorEdit: minor, message });
        toast("已保存到 Wiki");
        props.onSaved(target.pageId);
      } else {
        const id = await api.wikiCreate({ space: target.request.space, parent: target.request.parent, title, xhtml, fragments: session.fragments });
        toast("已创建页面");
        props.onSaved(id);
      }
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setSaving(false);
    }
  };

  return (
    <Modal
      title={target.kind === "edit" ? "保存到 Wiki" : "创建 Wiki 页面"}
      wide
      onClose={props.onClose}
      footer={
        <>
          <button className="btn" onClick={props.onClose}>
            返回编辑
          </button>
          <button className="btn primary" disabled={saving || nothing || !title.trim()} onClick={save}>
            {saving ? "保存中…" : target.kind === "edit" ? "保存" : "创建"}
          </button>
        </>
      }
    >
      {!title.trim() && <ErrorBox message="请填写页面标题" />}
      {nothing ? (
        <p className="muted">内容没有变化。</p>
      ) : target.kind === "edit" ? (
        <>
          {titleChanged && (
            <p>
              标题：<span className="strike muted">{session.title}</span> → {title}
            </p>
          )}
          <div className="wiki-save-diff">
            <WikiDiff diff={result.diff} />
          </div>
          <label className="form-field">
            <span>修改说明（可选）</span>
            <input value={message} onChange={(e) => setMessage(e.target.value)} placeholder="例如：补充部署步骤" />
          </label>
          <label className="checkbox">
            <input type="checkbox" checked={minor} onChange={(e) => setMinor(e.target.checked)} />
            小修改（不通知关注这个页面的人）
          </label>
          <p className="muted small">保存时会检查页面是否在你开始编辑后被别人修改过；如果是，不会覆盖，请刷新后重新编辑。</p>
        </>
      ) : (
        <p>
          将在 <strong>{target.request.space}</strong> 空间{target.request.parentTitle ? <>的「{target.request.parentTitle}」下</> : "顶层"}创建页面「{title}」。
        </p>
      )}
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}
