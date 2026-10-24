import { useEffect, useRef, useState, type ReactNode } from "react";
import { EditorContent, useEditor, type Editor } from "@tiptap/react";
import { mergeAttributes } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { Markdown } from "@tiptap/markdown";
import { TaskItem, TaskList } from "@tiptap/extension-list";
import { TableKit } from "@tiptap/extension-table";
import Image from "@tiptap/extension-image";
import { Placeholder } from "@tiptap/extensions";
import { openLink } from "../../../lib/links";
import { useNav } from "../../../state/nav";
import {
  Bold,
  CheckSquare,
  CircleDot,
  Code,
  Heading1,
  Heading2,
  Heading3,
  Italic,
  Link2,
  List,
  ListChecks,
  ListOrdered,
  Minus,
  Quote,
  Redo2,
  SquareCode,
  Strikethrough,
  Table,
  Undo2,
} from "lucide-react";
import { api, errorMessage } from "../../../api";
import { assetUrl, systemPath } from "../../../lib/asset";
import { useSettings } from "../../../state/settings";
import { ASSET_PREFIX, DOC_PREFIX } from "./convert";
import { DocLinks } from "./docLinks";
import { IssueRefs, setIssueLookupEnabled } from "./issueRefs";

const PREFIX = navigator.userAgent.includes("Windows") ? "http://nextworkzone.localhost/" : "nextworkzone://localhost/";

interface Props {
  /** 当前文档 id，[[ 链接列表中排除自己 */
  docId: string | null;
  /** 初始内容（Markdown）；之后外部内容变化（例如同步）且未在编辑时也会更新 */
  value: string;
  onChange: (markdown: string) => void;
  placeholder?: string;
  /** 选中文字后“转为待办” */
  onCreateTodos?: (lines: string[]) => void;
  /** 选中文字后“创建 Jira 问题” */
  onCreateIssue?: (text: string, insertKey: (key: string) => void) => void;
  /** Ctrl+点击内部链接、问题键时打开 */
  onOpenDoc: (id: string) => void;
  onOpenIssue: (key: string) => void;
  footer?: ReactNode;
}

/** 工作空间文档编辑器：Markdown 存储，所见即所得编辑，支持任务列表、表格、图片、问题键识别和 [[ 文档链接。 */
export function NoteEditor(props: Props) {
  const { baseUrl, isReady, sessionVersion } = useSettings();
  const [error, setError] = useState<string | null>(null);
  /** 正在编辑的链接地址（工具栏中的输入框） */
  const [linkDraft, setLinkDraft] = useState<string | null>(null);
  const emitted = useRef(props.value);
  const timer = useRef<number | null>(null);
  const propsRef = useRef(props);
  propsRef.current = props;
  setIssueLookupEnabled(isReady("jira"));

  /** 图片显示地址：本地图片和需要认证的系统图片都经由代理。 */
  const displaySrc = (src: string): string => {
    if (src.startsWith(ASSET_PREFIX)) return `${PREFIX}ws/${encodeURIComponent(src.slice(ASSET_PREFIX.length))}`;
    for (const service of ["jira", "confluence", "gitlab"] as const) {
      const path = systemPath(src, baseUrl(service));
      if (path && baseUrl(service)) return assetUrl(service, path, sessionVersion);
    }
    return src;
  };
  const displayRef = useRef(displaySrc);
  displayRef.current = displaySrc;
  const { navigate } = useNav();
  const navigateRef = useRef(navigate);
  navigateRef.current = navigate;
  const baseUrlRef = useRef(baseUrl);
  baseUrlRef.current = baseUrl;

  const editor = useEditor({
    shouldRerenderOnTransaction: true,
    extensions: [
      StarterKit.configure({
        link: {
          openOnClick: false,
          autolink: true,
          isAllowedUri: (url, ctx) => url.startsWith("ws://") || ctx.defaultValidate(url),
        },
      }),
      Markdown,
      TaskList,
      TaskItem.configure({ nested: true }),
      TableKit.configure({ table: { resizable: false } }),
      Image.extend({
        renderHTML({ HTMLAttributes }) {
          return ["img", mergeAttributes(HTMLAttributes, { src: displayRef.current(String(HTMLAttributes.src ?? "")) })];
        },
      }),
      Placeholder.configure({ placeholder: props.placeholder ?? "开始记录…  输入 [[ 链接其他文档，粘贴截图，写问题键自动关联" }),
      IssueRefs,
      DocLinks.configure({ currentId: () => propsRef.current.docId }),
    ],
    content: props.value,
    contentType: "markdown",
    onUpdate: ({ editor }) => {
      if (timer.current) window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => flush(editor), 400);
    },
    editorProps: {
      handlePaste: (_view, event) => {
        const images = Array.from(event.clipboardData?.files ?? []).filter((f) => f.type.startsWith("image/"));
        if (images.length === 0) return false;
        event.preventDefault();
        void pasteImages(images);
        return true;
      },
      handleDrop: (_view, event) => {
        const images = Array.from((event as DragEvent).dataTransfer?.files ?? []).filter((f) => f.type.startsWith("image/"));
        if (images.length === 0) return false;
        event.preventDefault();
        void pasteImages(images);
        return true;
      },
      handleDOMEvents: {
        click: (_view, event) => {
          const target = event.target as HTMLElement;
          const issue = target.closest<HTMLElement>("[data-issue-key]");
          const anchor = target.closest("a");
          const mod = event.ctrlKey;
          if (issue && mod) {
            event.preventDefault();
            propsRef.current.onOpenIssue(issue.dataset.issueKey!);
            return true;
          }
          if (anchor) {
            event.preventDefault();
            const href = anchor.getAttribute("href") ?? "";
            if (!mod) return true;
            if (href.startsWith(DOC_PREFIX)) propsRef.current.onOpenDoc(href.slice(DOC_PREFIX.length));
            // Jira、Wiki、GitLab 的地址在应用内打开
            else if (/^(https?|mailto):/.test(href)) void openLink(href, baseUrlRef.current, navigateRef.current);
            return true;
          }
          return false;
        },
      },
    },
  });

  const flush = (ed: Editor) => {
    timer.current = null;
    const markdown = ed.getMarkdown();
    if (markdown === emitted.current) return;
    emitted.current = markdown;
    propsRef.current.onChange(markdown);
  };

  // 离开前提交未保存的输入
  useEffect(
    () => () => {
      if (timer.current && editor) {
        window.clearTimeout(timer.current);
        flush(editor);
      }
    },
    [editor],
  );

  // 外部内容变化（同步、另一处修改）且当前没在编辑时更新编辑器
  useEffect(() => {
    if (!editor || props.value === emitted.current || editor.isFocused) return;
    emitted.current = props.value;
    editor.commands.setContent(props.value, { contentType: "markdown", emitUpdate: false });
  }, [editor, props.value]);

  const pasteImages = async (files: File[]) => {
    for (const file of files) {
      try {
        const data = await new Promise<string>((resolve, reject) => {
          const reader = new FileReader();
          reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ""));
          reader.onerror = () => reject(reader.error);
          reader.readAsDataURL(file);
        });
        const asset = await api.wsSaveAsset(data, file.type);
        editor?.chain().focus().setImage({ src: `${ASSET_PREFIX}${asset.id}` }).run();
      } catch (e) {
        setError(`图片保存失败：${errorMessage(e)}`);
      }
    }
  };

  if (!editor) return null;

  const { from, to, empty } = editor.state.selection;
  const selectedText = empty ? "" : editor.state.doc.textBetween(from, to, "\n");

  const setLink = () => setLinkDraft((editor.getAttributes("link").href as string | undefined) ?? "https://");
  const applyLink = () => {
    const url = (linkDraft ?? "").trim();
    setLinkDraft(null);
    if (!url || url === "https://") editor.chain().focus().extendMarkRange("link").unsetLink().run();
    else editor.chain().focus().extendMarkRange("link").setLink({ href: url }).run();
  };

  const tools: { icon: ReactNode; title: string; active?: boolean; run: () => void; disabled?: boolean }[][] = [
    [
      { icon: <Heading1 size={15} />, title: "标题 1", active: editor.isActive("heading", { level: 1 }), run: () => editor.chain().focus().toggleHeading({ level: 1 }).run() },
      { icon: <Heading2 size={15} />, title: "标题 2", active: editor.isActive("heading", { level: 2 }), run: () => editor.chain().focus().toggleHeading({ level: 2 }).run() },
      { icon: <Heading3 size={15} />, title: "标题 3", active: editor.isActive("heading", { level: 3 }), run: () => editor.chain().focus().toggleHeading({ level: 3 }).run() },
    ],
    [
      { icon: <Bold size={15} />, title: "粗体（Ctrl+B）", active: editor.isActive("bold"), run: () => editor.chain().focus().toggleBold().run() },
      { icon: <Italic size={15} />, title: "斜体（Ctrl+I）", active: editor.isActive("italic"), run: () => editor.chain().focus().toggleItalic().run() },
      { icon: <Strikethrough size={15} />, title: "删除线", active: editor.isActive("strike"), run: () => editor.chain().focus().toggleStrike().run() },
      { icon: <Code size={15} />, title: "行内代码", active: editor.isActive("code"), run: () => editor.chain().focus().toggleCode().run() },
      { icon: <Link2 size={15} />, title: "链接（输入 [[ 链接文档）", active: editor.isActive("link"), run: setLink },
    ],
    [
      { icon: <List size={15} />, title: "无序列表", active: editor.isActive("bulletList"), run: () => editor.chain().focus().toggleBulletList().run() },
      { icon: <ListOrdered size={15} />, title: "有序列表", active: editor.isActive("orderedList"), run: () => editor.chain().focus().toggleOrderedList().run() },
      { icon: <ListChecks size={15} />, title: "任务列表", active: editor.isActive("taskList"), run: () => editor.chain().focus().toggleTaskList().run() },
      { icon: <Quote size={15} />, title: "引用", active: editor.isActive("blockquote"), run: () => editor.chain().focus().toggleBlockquote().run() },
      { icon: <SquareCode size={15} />, title: "代码块", active: editor.isActive("codeBlock"), run: () => editor.chain().focus().toggleCodeBlock().run() },
      { icon: <Table size={15} />, title: "插入表格", run: () => editor.chain().focus().insertTable({ rows: 3, cols: 3, withHeaderRow: true }).run() },
      { icon: <Minus size={15} />, title: "分隔线", run: () => editor.chain().focus().setHorizontalRule().run() },
    ],
    [
      { icon: <Undo2 size={15} />, title: "撤销（Ctrl+Z）", disabled: !editor.can().undo(), run: () => editor.chain().focus().undo().run() },
      { icon: <Redo2 size={15} />, title: "重做（Ctrl+Shift+Z）", disabled: !editor.can().redo(), run: () => editor.chain().focus().redo().run() },
    ],
  ];

  return (
    <div className="note-editor">
      <div className="note-toolbar" onMouseDown={(e) => (e.target as HTMLElement).closest(".tool") && e.preventDefault()}>
        {tools.map((group, i) => (
          <span className="tool-group" key={i}>
            {group.map((t) => (
              <button key={t.title} type="button" className={`tool${t.active ? " active" : ""}`} title={t.title} disabled={t.disabled} onClick={t.run}>
                {t.icon}
              </button>
            ))}
          </span>
        ))}
        {editor.isActive("table") && (
          <span className="tool-group">
            <button type="button" className="tool text" onClick={() => editor.chain().focus().addRowAfter().run()}>
              +行
            </button>
            <button type="button" className="tool text" onClick={() => editor.chain().focus().addColumnAfter().run()}>
              +列
            </button>
            <button type="button" className="tool text" onClick={() => editor.chain().focus().deleteRow().run()}>
              −行
            </button>
            <button type="button" className="tool text" onClick={() => editor.chain().focus().deleteColumn().run()}>
              −列
            </button>
            <button type="button" className="tool text" onClick={() => editor.chain().focus().deleteTable().run()}>
              删表
            </button>
          </span>
        )}
        {linkDraft !== null && (
          <span className="tool-group link-edit">
            <input
              autoFocus
              value={linkDraft}
              placeholder="链接地址，留空则移除链接"
              onChange={(e) => setLinkDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  applyLink();
                } else if (e.key === "Escape") {
                  e.preventDefault();
                  setLinkDraft(null);
                }
              }}
            />
            <button type="button" className="btn small-btn" onClick={applyLink}>
              确定
            </button>
          </span>
        )}
        <span className="spacer" />
        {selectedText.trim() && props.onCreateTodos && (
          <button type="button" className="btn small-btn" title="每行一条待办" onClick={() => props.onCreateTodos!(selectedText.split("\n").map((l) => l.trim()).filter(Boolean))}>
            <CheckSquare size={13} />
            转为待办
          </button>
        )}
        {selectedText.trim() && props.onCreateIssue && isReady("jira") && (
          <button
            type="button"
            className="btn small-btn"
            onClick={() =>
              props.onCreateIssue!(selectedText, (key) => {
                editor.chain().focus().setTextSelection(to).insertContent(` ${key}`).run();
              })
            }
          >
            <CircleDot size={13} />
            创建 Jira 问题
          </button>
        )}
      </div>
      <EditorContent editor={editor} className="note-content rich" />
      {error && <div className="wiki-note error">{error}</div>}
      <div className="note-footer muted small">
        <span className="grow">Ctrl+点击打开链接和问题 · 输入 [[ 链接文档 · 可粘贴截图</span>
        {props.footer}
      </div>
    </div>
  );
}
