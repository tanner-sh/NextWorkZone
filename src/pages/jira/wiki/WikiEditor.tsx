import { forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState, type ReactNode } from "react";
import { createPortal } from "react-dom";
import DOMPurify from "dompurify";
import {
  Bold,
  Code,
  Heading,
  Italic,
  Link2,
  List,
  ListOrdered,
  Minus,
  Palette,
  Quote,
  SquareCode,
  Strikethrough,
  Table,
  Underline,
} from "lucide-react";
import { api, errorMessage, type UserRef } from "../../../api";
import { assetUrl, systemPath } from "../../../lib/asset";
import { usePageActive } from "../../../state/nav";
import { useSettings } from "../../../state/settings";
import { FILE_DROP_EVENT } from "../../../components/FileDropLayer";
import { htmlToWiki } from "./htmlToWiki";
import { markAttachmentImages, unsupportedContent } from "./prepare";

/** 粘贴或拖进编辑器、尚未上传的文件。保存时作为附件上传，wiki 中图片以 `!文件名!`、其他文件以 `[^文件名]` 引用。 */
export interface PendingImage {
  filename: string;
  path: string;
}

/** 仍被文本引用的待上传文件（插入后又删掉的不再上传）。 */
export function referencedImages(pending: PendingImage[], texts: (string | null | undefined)[]): PendingImage[] {
  const all = texts.filter(Boolean).join("\n");
  return pending.filter((img) => all.includes(`!${img.filename}`) || all.includes(`[^${img.filename}]`));
}

const IMAGE_EXT = /\.(png|jpe?g|gif|webp|bmp)$/i;

const escapeHtml = (s: string) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");

type Mode = "visual" | "text";
const MODE_KEY = "nextworkzone.jira.editorMode";

function savedMode(): Mode {
  try {
    return localStorage.getItem(MODE_KEY) === "text" ? "text" : "visual";
  } catch {
    return "visual";
  }
}

/** 渲染前把待上传图片换成占位地址，渲染后再换回本地预览，否则 Jira 会报“找不到附件”。 */
const PENDING_PREFIX = "https://pending.nextworkzone.invalid/";

const FORMAT_KEYS: Record<string, string> = { b: "bold", i: "italic", u: "underline" };

const COLORS = ["#de350b", "#ff991f", "#00875a", "#0065ff", "#6554c0", "#97a0af"];

interface Props {
  value: string;
  onChange: (wiki: string) => void;
  /** 用于解析 `!附件名!`；创建问题时为空。 */
  issueKey: string | null;
  /** 粘贴图片后回调；不提供时不支持粘贴图片。 */
  onImage?: (image: PendingImage) => void;
  minHeight?: number;
  placeholder?: string;
  /** 放在模式切换按钮旁的额外内容（例如评论的发送按钮）。 */
  footer?: ReactNode;
  onSubmitShortcut?: () => void;
}

/**
 * Jira 字段的富文本编辑器：可视化模式下编辑 Jira 渲染出的 HTML，内容变化时转换回 wiki 标记；
 * 文本模式直接编辑 wiki 标记。可视化模式下未做修改时保持原始 wiki 不变，避免无谓的格式变化。
 */
export function WikiEditor(props: Props) {
  const { value, onChange, issueKey } = props;
  const { baseUrl: baseUrlOf, sessionVersion } = useSettings();
  const baseUrl = baseUrlOf("jira");
  const [mode, setMode] = useState<Mode>(savedMode);
  const [loading, setLoading] = useState(false);
  const [warning, setWarning] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [linkOpen, setLinkOpen] = useState(false);
  const [colorOpen, setColorOpen] = useState(false);
  const editorRef = useRef<HTMLDivElement>(null);
  /** 最近一次由本编辑器产生的值；外部传入的值与之不同时说明内容被外部替换，需要重新渲染。 */
  const emitted = useRef<string | null>(null);
  const timer = useRef<number | null>(null);
  /** 本地预览地址：文件名 → blob URL */
  const previews = useRef(new Map<string, string>());
  const savedRange = useRef<Range | null>(null);
  const textRef = useRef<HTMLTextAreaElement>(null);
  const rootRef = useRef<HTMLDivElement>(null);
  /** 正在输入的 @提及：关键词、弹出位置，以及替换范围 */
  const [mention, setMention] = useState<Mention | null>(null);
  const mentionRef = useRef<MentionHandle>(null);

  const switchMode = (next: Mode) => {
    flush();
    setMode(next);
    try {
      localStorage.setItem(MODE_KEY, next);
    } catch {
      // 不记忆
    }
  };

  // ---------- wiki → 可视化 ----------

  const load = useCallback(
    async (wiki: string) => {
      const editor = editorRef.current;
      if (!editor) return;
      emitted.current = wiki;
      setError(null);
      if (!wiki.trim()) {
        editor.innerHTML = "<p><br></p>";
        setWarning(null);
        return;
      }
      setLoading(true);
      try {
        let markup = wiki;
        for (const name of previews.current.keys()) markup = markup.split(`!${name}`).join(`!${PENDING_PREFIX}${encodeURIComponent(name)}`);
        const html = await api.jiraRenderWiki(markup, issueKey);
        const fragment = DOMPurify.sanitize(html, { RETURN_DOM_FRAGMENT: true, ADD_ATTR: ["file-preview-title"] });
        markAttachmentImages(fragment);
        fragment.querySelectorAll("img").forEach((img) => {
          const src = img.getAttribute("src") ?? "";
          if (src.startsWith(PENDING_PREFIX)) {
            const name = decodeURIComponent(src.slice(PENDING_PREFIX.length));
            img.dataset.filename = name;
            img.setAttribute("src", previews.current.get(name) ?? "");
            return;
          }
          const path = systemPath(src, baseUrl);
          if (path) img.setAttribute("src", assetUrl("jira", path, sessionVersion));
        });
        // 渲染器加的标题锚点没有意义
        fragment.querySelectorAll("a[name]:not([href])").forEach((a) => a.remove());
        const unsupported = unsupportedContent(fragment);
        setWarning(unsupported.length > 0 ? "内容包含可视化模式无法完整保留的格式（宏或插件内容），在此模式下修改可能丢失这些格式，建议切换到文本模式编辑。" : null);
        if (emitted.current !== wiki) return; // 渲染期间内容又被替换
        editor.replaceChildren(fragment);
        if (!editor.innerHTML.trim()) editor.innerHTML = "<p><br></p>";
      } catch (e) {
        setError(`无法显示可视化内容：${errorMessage(e)}`);
      } finally {
        setLoading(false);
      }
    },
    [issueKey, baseUrl, sessionVersion],
  );

  // 进入可视化模式，或内容被外部替换（例如评论发送后清空）时重新渲染
  useEffect(() => {
    if (mode !== "visual") return;
    if (emitted.current === value && editorRef.current?.childNodes.length) return;
    void load(value);
  }, [mode, value, load]);

  // ---------- 可视化 → wiki ----------

  const convert = useCallback(() => {
    const editor = editorRef.current;
    if (!editor) return;
    const wiki = htmlToWiki(editor);
    emitted.current = wiki;
    onChange(wiki);
  }, [onChange]);

  const schedule = () => {
    if (timer.current) window.clearTimeout(timer.current);
    timer.current = window.setTimeout(() => {
      timer.current = null;
      convert();
    }, 250);
  };

  /** 立即提交尚未转换的修改（失去焦点、切换模式时）。 */
  const flush = () => {
    if (timer.current) {
      window.clearTimeout(timer.current);
      timer.current = null;
      convert();
    }
  };

  useEffect(() => () => flush(), []);

  // ---------- @提及 ----------

  const detectVisualMention = () => {
    const sel = window.getSelection();
    const node = sel?.anchorNode;
    if (!sel || !sel.isCollapsed || !node || node.nodeType !== Node.TEXT_NODE || !editorRef.current?.contains(node)) return setMention(null);
    const match = MENTION_RE.exec((node.textContent ?? "").slice(0, sel.anchorOffset));
    if (!match) return setMention(null);
    const range = document.createRange();
    range.setStart(node, sel.anchorOffset - match[1].length - 1);
    range.setEnd(node, sel.anchorOffset);
    const rect = range.getBoundingClientRect();
    setMention({ query: match[1], x: rect.left, y: rect.bottom, range });
  };

  const detectTextMention = () => {
    const area = textRef.current;
    if (!area || area.selectionStart !== area.selectionEnd) return setMention(null);
    const match = MENTION_RE.exec(area.value.slice(0, area.selectionStart));
    if (!match) return setMention(null);
    // 文本框里拿不到光标坐标，显示在输入框下方
    const rect = area.getBoundingClientRect();
    setMention({ query: match[1], x: rect.left + 8, y: rect.bottom, start: area.selectionStart - match[1].length - 1, end: area.selectionStart });
  };

  const insertMention = (user: UserRef) => {
    const current = mention;
    setMention(null);
    if (!current) return;
    if (current.range) {
      const range = current.range;
      range.deleteContents();
      const link = document.createElement("a");
      link.className = "user-hover";
      link.setAttribute("rel", user.name);
      link.dataset.username = user.name;
      link.textContent = `@${user.displayName}`;
      const space = document.createTextNode("\u00a0");
      range.insertNode(space);
      range.insertNode(link);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      const after = document.createRange();
      after.setStartAfter(space);
      sel?.addRange(after);
      editorRef.current?.focus();
      schedule();
    } else if (current.start !== undefined && current.end !== undefined) {
      const text = `${value.slice(0, current.start)}[~${user.name}] ${value.slice(current.end)}`;
      emitted.current = text;
      onChange(text);
      const caret = current.start + user.name.length + 4;
      requestAnimationFrame(() => {
        textRef.current?.focus();
        textRef.current?.setSelectionRange(caret, caret);
      });
    }
  };

  // ---------- 编辑命令 ----------

  const exec = (command: string, arg?: string) => {
    // 焦点不在编辑区（例如在链接输入框里）时，恢复之前的选区
    if (!editorRef.current?.contains(document.activeElement)) restoreSelection();
    editorRef.current?.focus();
    document.execCommand(command, false, arg);
    schedule();
  };

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

  const wrapInline = (tag: string) => {
    if (!editorRef.current?.contains(document.activeElement)) restoreSelection();
    const sel = window.getSelection();
    if (!sel || sel.rangeCount === 0 || sel.isCollapsed) return;
    const range = sel.getRangeAt(0);
    const el = document.createElement(tag);
    el.appendChild(range.extractContents());
    range.insertNode(el);
    sel.removeAllRanges();
    schedule();
  };

  const insertTable = () => {
    const cells = (tag: string) => Array.from({ length: 3 }, () => `<${tag}><br></${tag}>`).join("");
    exec("insertHTML", `<table><tbody><tr>${cells("th")}</tr><tr>${cells("td")}</tr><tr>${cells("td")}</tr></tbody></table><p><br></p>`);
  };

  // ---------- 粘贴 ----------

  const onPaste = (e: React.ClipboardEvent<HTMLDivElement>) => {
    const images = Array.from(e.clipboardData.files).filter((f) => f.type.startsWith("image/"));
    if (images.length > 0 && props.onImage) {
      e.preventDefault();
      images.forEach((file, i) => void pasteImage(file, i));
      return;
    }
    const html = e.clipboardData.getData("text/html");
    if (html) {
      e.preventDefault();
      // 只保留结构和基本格式，去掉网页、Office 带来的样式和脚本
      const clean = DOMPurify.sanitize(html, {
        ALLOWED_TAGS: ["p", "div", "br", "b", "strong", "i", "em", "u", "ins", "s", "del", "strike", "sup", "sub", "code", "tt", "pre", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "thead", "tbody", "tr", "th", "td", "a", "blockquote", "hr", "span", "font"],
        ALLOWED_ATTR: ["href", "style", "color"],
      });
      document.execCommand("insertHTML", false, clean);
      schedule();
    }
  };

  const pasteImage = async (file: File, index: number) => {
    const filename = imageName(file, index);
    const url = URL.createObjectURL(file);
    previews.current.set(filename, url);
    document.execCommand("insertHTML", false, `<img src="${url}" data-filename="${filename}" alt="">`);
    schedule();
    try {
      const path = await api.jiraSavePastedImage(await toBase64(file), filename);
      props.onImage?.({ filename, path });
    } catch (err) {
      editorRef.current?.querySelectorAll(`img[data-filename="${CSS.escape(filename)}"]`).forEach((img) => img.remove());
      setError(`图片粘贴失败：${errorMessage(err)}`);
      schedule();
    }
  };

  // ---------- 拖入文件 ----------

  /** 拖进编辑器的文件：在光标处（没有光标时在末尾）插入引用，保存时作为附件上传。 */
  const dropFiles = async (paths: string[]) => {
    const files = paths.map((path) => ({ path, filename: path.split(/[\\/]/).pop() ?? path }));
    if (mode === "text") {
      const area = textRef.current;
      const refs = files.map((f) => (IMAGE_EXT.test(f.filename) ? `!${f.filename}!` : `[^${f.filename}]`)).join(" ");
      const at = area && document.activeElement === area ? area.selectionStart : value.length;
      const before = value.slice(0, at);
      const text = `${before}${before && !/\s$/.test(before) ? " " : ""}${refs} ${value.slice(at)}`;
      emitted.current = text;
      onChange(text);
    } else {
      let html = "";
      for (const f of files) {
        const preview = IMAGE_EXT.test(f.filename) ? await api.localImagePreview(f.path).catch(() => null) : null;
        if (preview) {
          previews.current.set(f.filename, preview);
          html += `<img src="${preview}" data-filename="${escapeHtml(f.filename)}" alt="">&nbsp;`;
        } else {
          html += `<a href="#" data-attachment="${escapeHtml(f.filename)}">${escapeHtml(f.filename)}</a>&nbsp;`;
        }
      }
      if (!editorRef.current?.contains(document.activeElement)) {
        if (savedRange.current) restoreSelection();
        else {
          // 没有光标位置时放到末尾
          const range = document.createRange();
          range.selectNodeContents(editorRef.current!);
          range.collapse(false);
          window.getSelection()?.removeAllRanges();
          window.getSelection()?.addRange(range);
        }
      }
      editorRef.current?.focus();
      document.execCommand("insertHTML", false, html);
      schedule();
    }
    files.forEach((f) => props.onImage?.(f));
  };
  const dropRef = useRef(dropFiles);
  dropRef.current = dropFiles;
  const canDrop = Boolean(props.onImage);
  useEffect(() => {
    const root = rootRef.current;
    if (!root || !canDrop) return;
    const onDrop = (e: Event) => void dropRef.current((e as CustomEvent<string[]>).detail);
    root.addEventListener(FILE_DROP_EVENT, onDrop);
    return () => root.removeEventListener(FILE_DROP_EVENT, onDrop);
  }, [canDrop]);

  // ---------- 渲染 ----------

  const tools: { icon: ReactNode; title: string; run: () => void }[] = [
    { icon: <Bold size={15} />, title: "粗体（Ctrl+B）", run: () => exec("bold") },
    { icon: <Italic size={15} />, title: "斜体（Ctrl+I）", run: () => exec("italic") },
    { icon: <Underline size={15} />, title: "下划线（Ctrl+U）", run: () => exec("underline") },
    { icon: <Strikethrough size={15} />, title: "删除线", run: () => exec("strikeThrough") },
    { icon: <Code size={15} />, title: "行内代码", run: () => wrapInline("code") },
  ];
  const blockTools: { icon: ReactNode; title: string; run: () => void }[] = [
    { icon: <List size={15} />, title: "无序列表", run: () => exec("insertUnorderedList") },
    { icon: <ListOrdered size={15} />, title: "有序列表", run: () => exec("insertOrderedList") },
    { icon: <Quote size={15} />, title: "引用", run: () => exec("formatBlock", "blockquote") },
    { icon: <SquareCode size={15} />, title: "代码块（原样显示）", run: () => exec("formatBlock", "pre") },
    { icon: <Table size={15} />, title: "插入表格", run: insertTable },
    { icon: <Minus size={15} />, title: "分隔线", run: () => exec("insertHorizontalRule") },
  ];

  return (
    <div ref={rootRef} className={`wiki-editor${mode === "text" ? " text-mode" : ""}`} data-file-drop={canDrop ? "插入到编辑区，保存时作为附件上传" : undefined}>
      {mode === "visual" && (
        // 点击工具栏时保留编辑区里的选区；下拉框和输入框需要正常获得焦点
        <div className="wiki-toolbar" onMouseDown={(e) => !["INPUT", "SELECT", "OPTION"].includes((e.target as HTMLElement).tagName) && e.preventDefault()}>
          <span className="tool-select">
            <Heading size={15} />
            <select
              value=""
              title="段落格式"
              onChange={(e) => {
                exec("formatBlock", e.target.value);
                e.target.value = "";
              }}
            >
              <option value="" disabled>
                段落
              </option>
              <option value="p">正文</option>
              <option value="h1">标题 1</option>
              <option value="h2">标题 2</option>
              <option value="h3">标题 3</option>
              <option value="h4">标题 4</option>
            </select>
          </span>
          <span className="tool-sep" />
          {tools.map((t) => (
            <button key={t.title} type="button" className="tool" title={t.title} onClick={t.run}>
              {t.icon}
            </button>
          ))}
          <span className="tool-popover-anchor">
            <button type="button" className="tool" title="文字颜色" onClick={() => setColorOpen((v) => !v)}>
              <Palette size={15} />
            </button>
            {colorOpen && (
              <span className="tool-popover colors">
                {COLORS.map((c) => (
                  <button
                    key={c}
                    type="button"
                    style={{ background: c }}
                    title={c}
                    onClick={() => {
                      setColorOpen(false);
                      exec("foreColor", c);
                    }}
                  />
                ))}
                <button type="button" className="clear-color" title="默认颜色" onClick={() => (setColorOpen(false), exec("foreColor", "#000000"))}>
                  ×
                </button>
              </span>
            )}
          </span>
          <span className="tool-popover-anchor">
            <button type="button" className="tool" title="链接" onClick={() => setLinkOpen((v) => !v)}>
              <Link2 size={15} />
            </button>
            {linkOpen && (
              <LinkPopover
                onCancel={() => setLinkOpen(false)}
                onSubmit={(url) => {
                  setLinkOpen(false);
                  restoreSelection();
                  const sel = window.getSelection();
                  if (sel && !sel.isCollapsed) exec("createLink", url);
                  else exec("insertHTML", `<a href="${url.replace(/"/g, "&quot;")}">${url.replace(/</g, "&lt;")}</a>`);
                }}
              />
            )}
          </span>
          <span className="tool-sep" />
          {blockTools.map((t) => (
            <button key={t.title} type="button" className="tool" title={t.title} onClick={t.run}>
              {t.icon}
            </button>
          ))}
          {loading && <span className="muted small tool-status">加载中…</span>}
        </div>
      )}

      {mode === "visual" ? (
        <div
          ref={editorRef}
          className="wiki-visual rich"
          contentEditable
          suppressContentEditableWarning
          style={{ minHeight: props.minHeight ?? 120 }}
          data-placeholder={props.placeholder}
          onInput={() => {
            schedule();
            detectVisualMention();
          }}
          onBlur={() => {
            rememberSelection();
            flush();
            // 点击候选人时先失去焦点，稍后再关闭
            window.setTimeout(() => setMention(null), 150);
          }}
          onKeyUp={rememberSelection}
          onMouseUp={rememberSelection}
          onPaste={onPaste}
          onClick={(e) => {
            // 编辑区里的链接不跳转
            if ((e.target as HTMLElement).closest("a")) e.preventDefault();
          }}
          onFocus={() => document.execCommand("defaultParagraphSeparator", false, "p")}
          onKeyDown={(e) => {
            if (mention && mentionRef.current?.onKey(e)) return;
            const mod = e.ctrlKey;
            if (e.key === "Enter" && mod && props.onSubmitShortcut) {
              e.preventDefault();
              flush();
              props.onSubmitShortcut();
              return;
            }
            // 应用没有“格式”菜单，WebView 不会自动响应这些快捷键
            const shortcut = mod && !e.altKey && !e.shiftKey ? FORMAT_KEYS[e.key.toLowerCase()] : undefined;
            if (shortcut) {
              e.preventDefault();
              exec(shortcut);
            }
          }}
        />
      ) : (
        <textarea
          ref={textRef}
          className="wiki-text"
          value={value}
          placeholder={props.placeholder}
          style={{ minHeight: props.minHeight ?? 120 }}
          onChange={(e) => {
            emitted.current = e.target.value;
            onChange(e.target.value);
            detectTextMention();
          }}
          onBlur={() => window.setTimeout(() => setMention(null), 150)}
          onKeyDown={(e) => {
            if (mention && mentionRef.current?.onKey(e)) return;
            if (e.key === "Enter" && e.ctrlKey && props.onSubmitShortcut) {
              e.preventDefault();
              props.onSubmitShortcut();
            }
          }}
        />
      )}

      {mention && <MentionPopup ref={mentionRef} query={mention.query} x={mention.x} y={mention.y} issueKey={issueKey} onPick={insertMention} onClose={() => setMention(null)} />}

      {warning && mode === "visual" && <div className="wiki-note warn">{warning}</div>}
      {error && <div className="wiki-note error">{error}</div>}

      <div className="wiki-footer">
        <div className="segmented small-seg">
          <button type="button" className={mode === "visual" ? "active" : ""} onClick={() => mode !== "visual" && switchMode("visual")}>
            可视化
          </button>
          <button type="button" className={mode === "text" ? "active" : ""} onClick={() => mode !== "text" && switchMode("text")}>
            文本
          </button>
        </div>
        <span className="muted small grow">{mode === "text" ? "Jira wiki 标记语法" : props.onImage ? "可直接粘贴截图" : ""}</span>
        {props.footer}
      </div>
    </div>
  );
}

/** `@` 前面是开头、空白或括号，后面是不含空白的关键词。 */
const MENTION_RE = /(?:^|[\s\u00a0(（])@([^\s\u00a0@]{0,20})$/;

interface Mention {
  query: string;
  x: number;
  y: number;
  /** 可视化模式：要替换的“@关键词” */
  range?: Range;
  /** 文本模式：要替换的字符范围 */
  start?: number;
  end?: number;
}

interface MentionHandle {
  /** 处理候选列表的按键，返回是否已处理 */
  onKey: (e: React.KeyboardEvent) => boolean;
}

const MentionPopup = forwardRef<MentionHandle, { query: string; x: number; y: number; issueKey: string | null; onPick: (user: UserRef) => void; onClose: () => void }>(function MentionPopup(
  { query, x, y, issueKey, onPick, onClose },
  ref,
) {
  const [users, setUsers] = useState<UserRef[]>([]);
  const [active, setActive] = useState(0);
  const pageActive = usePageActive();
  useEffect(() => {
    if (!query) {
      setUsers([]);
      return;
    }
    let alive = true;
    const timer = window.setTimeout(() => {
      api.jiraFindUsers(query, "mention", issueKey, null).then(
        (list) => {
          if (!alive) return;
          setUsers(list.slice(0, 8));
          setActive(0);
        },
        () => alive && setUsers([]),
      );
    }, 200);
    return () => {
      alive = false;
      window.clearTimeout(timer);
    };
  }, [query, issueKey]);

  useImperativeHandle(ref, () => ({
    onKey: (e) => {
      if (e.nativeEvent.isComposing) return false;
      if (e.key === "Escape") {
        e.preventDefault();
        onClose();
        return true;
      }
      if (users.length === 0) return false;
      if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault();
        setActive((i) => (i + (e.key === "ArrowDown" ? 1 : users.length - 1)) % users.length);
        return true;
      }
      if (e.key === "Enter" || e.key === "Tab") {
        e.preventDefault();
        onPick(users[active]);
        return true;
      }
      return false;
    },
  }));

  // 放到 body 下，不受对话框的裁剪和定位影响；所以所在页面隐藏时要自己隐藏
  if (!pageActive) return null;
  return createPortal(
    <div className="mention-popup" style={{ left: Math.min(x, window.innerWidth - 260), top: y + 4 }} onMouseDown={(e) => e.preventDefault()}>
      {!query && <div className="muted small mention-hint">输入姓名或用户名</div>}
      {query && users.length === 0 && <div className="muted small mention-hint">没有匹配的用户</div>}
      {users.map((u, i) => (
        <button key={u.name} type="button" className={i === active ? "active" : ""} onMouseEnter={() => setActive(i)} onClick={() => onPick(u)}>
          <span>{u.displayName}</span>
          <span className="muted small">{u.name}</span>
        </button>
      ))}
    </div>,
    document.body,
  );
});

function LinkPopover({ onSubmit, onCancel }: { onSubmit: (url: string) => void; onCancel: () => void }) {
  const [url, setUrl] = useState("https://");
  return (
    <span className="tool-popover link-popover">
      <input
        autoFocus
        value={url}
        onChange={(e) => setUrl(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            if (/^(https?|mailto):/.test(url.trim())) onSubmit(url.trim());
          } else if (e.key === "Escape") onCancel();
        }}
      />
      <button type="button" className="btn small-btn" disabled={!/^(https?|mailto):/.test(url.trim())} onClick={() => onSubmit(url.trim())}>
        确定
      </button>
    </span>
  );
}

/** 读出文件内容的 base64（去掉 data URL 前缀）。 */
function toBase64(file: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ""));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}

const pad = (n: number, w = 2) => String(n).padStart(w, "0");

/** 与 Jira 网页粘贴截图的命名方式一致：image-2026-10-22-09-30-15-123.png */
function imageName(file: File, index: number): string {
  const d = new Date();
  const ext = file.type.split("/")[1]?.replace("jpeg", "jpg") || "png";
  const stamp = `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}-${pad(d.getHours())}-${pad(d.getMinutes())}-${pad(d.getSeconds())}-${pad(d.getMilliseconds(), 3)}`;
  return `image-${stamp}${index > 0 ? `-${index}` : ""}.${ext}`;
}
