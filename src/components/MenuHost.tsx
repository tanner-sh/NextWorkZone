// 全局右键菜单：替换 WebView 自带的菜单（只有“重新载入”），让应用内各处的右键行为一致。
//
// 规则：
// - 列表项等对象自己打开菜单（`menus.open` 或局部的 useContextMenu），调用 preventDefault 后这里不再处理；
// - 其余位置由这里按点击的目标生成：输入框（撤销、剪切、复制、粘贴、全选）、选中的文字、链接、图片、代码块；
// - 页面区域可以用 `contributeMenu` 附加本区域的操作（例如 Wiki 页面、问题详情）。
//   没有更具体的目标时这些操作直接列出，否则放在以区域命名的子菜单中；
// - 按住 ⌥ 右键仍显示系统菜单（调试时检查元素）。
import { createContext, useContext, useEffect, useRef, type ReactNode } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { CheckSquare, ClipboardPaste, Code2, Copy, ExternalLink, Image, Inbox, Link, Maximize2, Redo2, Scissors, Search, TextSelect, Undo2 } from "lucide-react";
import { api } from "../api";
import { copyText } from "../lib/clipboard";
import { refreshInbox } from "../lib/inbox";
import { openLink, routeUrl } from "../lib/links";
import { workspaceChanged } from "../lib/workspace";
import { useIssueMenu, type IssueMenuOptions, type IssueTarget } from "../pages/jira/issueMenu";
import { useWikiPageMenu, type WikiPageMenuOptions, type WikiPageTarget } from "../pages/wiki/pageMenu";
import { useNav } from "../state/nav";
import { useSettings } from "../state/settings";
import { useContextMenu, type MenuInput } from "./ContextMenu";
import { ATTACHMENT_PATH } from "./RichHtml";
import { guarded, toast } from "./Toast";

// ---------- 区域附加的操作 ----------

export interface MenuSection {
  /** 作为子菜单时的名称，例如“当前页面”“FYXM-123” */
  label: string;
  items: MenuInput[];
}

const SECTIONS = "__nwzMenuSections";
type WithSections = MouseEvent & { [SECTIONS]?: MenuSection[] };

/** 在区域的 onContextMenu 中调用：把本区域的操作附加到这次右键（内层区域先附加，排在前面）。 */
export function contributeMenu(e: React.MouseEvent, section: MenuSection) {
  const native = e.nativeEvent as WithSections;
  (native[SECTIONS] ??= []).push(section);
}

// ---------- 共用的对象菜单 ----------

interface MenuServices {
  /** 打开菜单（右键时在鼠标处，点击按钮时在按钮下方）；`target` 用于高亮所在行 */
  open: (e: React.MouseEvent | MouseEvent, items: MenuInput[], target?: string | null) => void;
  openAt: (el: HTMLElement, items: MenuInput[], target?: string | null) => void;
  /** 当前打开菜单的对象 */
  target: string | null;
  issue: (issue: IssueTarget | string, options?: IssueMenuOptions) => MenuInput[];
  wikiPage: (page: WikiPageTarget, options?: WikiPageMenuOptions) => MenuInput[];
  wikiSpace: ReturnType<typeof useWikiPageMenu>["spaceMenu"];
}

const MenuContext = createContext<MenuServices | null>(null);

export function useMenus(): MenuServices {
  const value = useContext(MenuContext);
  if (!value) throw new Error("useMenus 必须在 MenuHost 内使用");
  return value;
}

/** 主窗口：全局右键菜单，以及问题、Wiki 页面等对象的共用菜单。 */
export function MenuHost({ children }: { children: ReactNode }) {
  const menu = useContextMenu();
  const issueMenu = useIssueMenu();
  const wiki = useWikiPageMenu();
  const { baseUrl, isReady } = useSettings();
  const { navigate } = useNav();

  const services: MenuServices = {
    open: menu.open,
    openAt: menu.openAt,
    target: menu.target,
    issue: issueMenu.menuFor,
    wikiPage: wiki.pageMenu,
    wikiSpace: wiki.spaceMenu,
  };

  // 监听器只挂一次，通过 ref 取最新的服务
  const latest = useRef({ services, baseUrl, isReady, navigate });
  latest.current = { services, baseUrl, isReady, navigate };

  useEffect(() => {
    const onContextMenu = (e: MouseEvent) => {
      if (e.defaultPrevented || e.altKey) return;
      e.preventDefault();
      const { services, baseUrl, isReady, navigate } = latest.current;
      const target = e.target instanceof Element ? e.target : null;
      const specific = target
        ? targetItems(target, {
            issue: services.issue,
            wikiPage: services.wikiPage,
            route: (url) => routeUrl(url, baseUrl),
            open: (url) => openLink(url, baseUrl, navigate),
            search: {
              jira: isReady("jira") ? (text) => navigate({ page: "jira", jql: `text ~ "${text.replace(/["\\]/g, " ")}" ORDER BY updated DESC` }) : null,
              wiki: isReady("confluence") ? (text) => navigate({ page: "wiki", wikiSearch: text }) : null,
            },
          })
        : [];
      services.open(e, compose(specific, (e as WithSections)[SECTIONS] ?? []));
    };
    window.addEventListener("contextmenu", onContextMenu);
    return () => window.removeEventListener("contextmenu", onContextMenu);
  }, []);

  return (
    <MenuContext.Provider value={services}>
      {children}
      {menu.menu}
      {issueMenu.dialogs}
    </MenuContext.Provider>
  );
}

/** 其他窗口（快速记录、剪贴板面板）：只有输入框和选中文字的基本操作，同样不显示系统菜单。 */
export function BasicMenuHost({ children }: { children: ReactNode }) {
  const menu = useContextMenu();
  const open = useRef(menu.open);
  open.current = menu.open;
  useEffect(() => {
    const onContextMenu = (e: MouseEvent) => {
      if (e.defaultPrevented || e.altKey) return;
      e.preventDefault();
      if (e.target instanceof Element) open.current(e, targetItems(e.target, null));
    };
    window.addEventListener("contextmenu", onContextMenu);
    return () => window.removeEventListener("contextmenu", onContextMenu);
  }, []);
  return (
    <>
      {children}
      {menu.menu}
    </>
  );
}

/** 具体目标的操作在前；区域操作在没有具体目标时直接列出，否则作为子菜单。 */
function compose(specific: MenuInput[], sections: MenuSection[]): MenuInput[] {
  const rest = specific.length > 0 ? sections : sections.slice(1);
  return [
    ...specific,
    ...(specific.length === 0 && sections[0] ? sections[0].items : []),
    "separator",
    ...rest.map((s) => ({ label: s.label, children: s.items })),
  ];
}

// ---------- 按目标生成 ----------

interface TargetServices {
  issue: MenuServices["issue"];
  wikiPage: MenuServices["wikiPage"];
  route: (url: string) => ReturnType<typeof routeUrl>;
  open: (url: string) => Promise<void>;
  search: { jira: ((text: string) => void) | null; wiki: ((text: string) => void) | null };
}

const ISSUE_KEY = /^[A-Z][A-Z0-9_]+-\d+$/;
const NOT_TEXT_INPUT = new Set(["checkbox", "radio", "button", "submit", "reset", "range", "color", "file", "image", "hidden"]);

const copyItem = (label: string, text: string, icon: ReactNode = <Copy size={14} />): MenuInput => ({
  label,
  icon,
  onSelect: guarded(async () => {
    await copyText(text);
    toast("已复制");
  }),
});

/** 菜单标签中引用的文字：太长时截断。 */
const quote = (text: string) => {
  const line = text.replace(/\s+/g, " ").trim();
  return line.length > 16 ? `${line.slice(0, 16)}…` : line;
};

function targetItems(target: Element, services: TargetServices | null): MenuInput[] {
  const groups: MenuInput[][] = [];
  const editable = editableOf(target);
  if (editable) {
    groups.push(editItems(editable, services));
  } else {
    const text = selectedTextAt(target);
    if (text) groups.push(selectionItems(text, services));
  }
  if (services && !editable) {
    const anchor = target.closest<HTMLAnchorElement>("a[href]");
    if (anchor) groups.push(linkItems(anchor, services));
    else {
      // Wiki 页面中的 Jira 宏
      const macro = target.closest<HTMLElement>("[data-jira-key]");
      if (macro?.dataset.jiraKey && ISSUE_KEY.test(macro.dataset.jiraKey)) groups.push(services.issue(macro.dataset.jiraKey));
    }
  }
  if (target instanceof HTMLImageElement && !editable) groups.push(imageItems(target));
  const code = !editable && target.closest("pre");
  if (code) groups.push([copyItem("复制代码块", (code as HTMLElement).innerText.replace(/\n$/, ""), <Code2 size={14} />)]);
  return groups.flatMap((g, i) => (i > 0 ? ["separator" as const, ...g] : g));
}

function editableOf(target: Element): HTMLInputElement | HTMLTextAreaElement | HTMLElement | null {
  const el = target.closest<HTMLElement>("input, textarea, [contenteditable]");
  if (!el) return null;
  if (el instanceof HTMLInputElement && NOT_TEXT_INPUT.has(el.type)) return null;
  if (!(el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) && !el.isContentEditable) return null;
  return el;
}

/** 右键位置在选中的文字上时返回选中的文字。 */
function selectedTextAt(target: Element): string {
  const selection = window.getSelection();
  if (!selection || selection.isCollapsed || selection.rangeCount === 0) return "";
  const text = selection.toString().trim();
  return text && selection.getRangeAt(0).intersectsNode(target) ? text : "";
}

/** 选中的文字：复制，搜索，记为待办或存入收件箱；是问题键时附上问题菜单。 */
function selectionItems(text: string, services: TargetServices | null): MenuInput[] {
  if (!services) return [copyItem("复制", text)];
  const single = text.split("\n")[0].trim();
  const url = /^https?:\/\/\S+$/.test(text) ? text : null;
  return [
    copyItem("复制", text),
    ISSUE_KEY.test(text) && { label: `问题 ${text}`, children: services.issue(text) },
    url && { label: "打开链接", icon: <Link size={14} />, onSelect: guarded(() => services.open(url)) },
    "separator",
    services.search.jira && { label: `在 Jira 中搜索“${quote(text)}”`, icon: <Search size={14} />, onSelect: () => services.search.jira!(single) },
    services.search.wiki && { label: `在 Wiki 中搜索“${quote(text)}”`, icon: <Search size={14} />, onSelect: () => services.search.wiki!(single) },
    "separator",
    {
      label: "添加为待办",
      icon: <CheckSquare size={14} />,
      onSelect: guarded(async () => {
        await api.wsSaveTodo({ title: single.slice(0, 200) });
        workspaceChanged();
        toast("已添加待办");
      }),
    },
    {
      label: "存入收件箱",
      icon: <Inbox size={14} />,
      onSelect: guarded(async () => {
        const [title, ...rest] = text.split("\n");
        await api.wsCapture(title.trim().slice(0, 200), rest.join("\n").trim(), text.match(/https?:\/\/\S+/)?.[0] ?? null);
        workspaceChanged();
        void refreshInbox().catch(() => {});
        toast("已存入收件箱");
      }),
    },
  ];
}

/** 链接：系统中的问题和 Wiki 页面显示它们的菜单，其他链接打开或复制。 */
function linkItems(anchor: HTMLAnchorElement, services: TargetServices): MenuInput[] {
  const href = anchor.href;
  const text = anchor.innerText.trim();
  if (!/^(https?|mailto):/.test(href)) return [];
  const copyLinkText = text && text !== href && copyItem("复制链接文字", text);
  // 富文本中的链接交给它自己的点击处理（附件在应用内预览等）
  const inRich = Boolean(anchor.closest(".rich"));
  const follow = () => (inRich ? anchor.click() : void services.open(href));
  const route = services.route(href);
  // 指向问题、Wiki 页面的链接：与列表中右键这个对象的菜单相同
  if (route && route !== "wiki" && route.issueKey) return [...services.issue(route.issueKey), "separator", text !== route.issueKey && copyLinkText];
  if (route && route !== "wiki" && route.wikiPage && /^\d+$/.test(route.wikiPage)) return [...services.wikiPage({ id: route.wikiPage }), "separator", copyLinkText];
  const attachment = inRich && ATTACHMENT_PATH.test(href);
  return [
    { label: attachment ? "预览附件" : route ? "在应用内打开" : "打开链接", icon: <Link size={14} />, onSelect: follow },
    (route || attachment) && { label: "在浏览器中打开", icon: <ExternalLink size={14} />, onSelect: guarded(() => openUrl(href)) },
    "separator",
    copyItem(href.startsWith("mailto:") ? "复制邮件地址" : "复制链接", href.replace(/^mailto:/, "")),
    copyLinkText,
    copyItem("复制为 Markdown 链接", `[${text || href}](${href})`),
  ];
}

function imageItems(img: HTMLImageElement): MenuInput[] {
  return [
    img.closest(".rich") && {
      label: "查看大图",
      icon: <Maximize2 size={14} />,
      // 富文本双击图片时放大
      onSelect: () => img.dispatchEvent(new MouseEvent("dblclick", { bubbles: true })),
    },
    {
      label: "复制图片",
      icon: <Image size={14} />,
      onSelect: guarded(async () => {
        // 剪贴板只稳定支持 PNG：先转换；用 Promise 构造以保留这次点击的授权
        const png = fetch(img.currentSrc || img.src)
          .then((r) => r.blob())
          .then(toPng);
        await navigator.clipboard.write([new ClipboardItem({ "image/png": png })]);
        toast("已复制图片");
      }),
    },
  ];
}

async function toPng(blob: Blob): Promise<Blob> {
  if (blob.type === "image/png") return blob;
  const bitmap = await createImageBitmap(blob);
  const canvas = document.createElement("canvas");
  canvas.width = bitmap.width;
  canvas.height = bitmap.height;
  canvas.getContext("2d")!.drawImage(bitmap, 0, 0);
  return new Promise((resolve, reject) => canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("无法转换图片"))), "image/png"));
}

// ---------- 输入框 ----------

/**
 * 菜单打开后焦点在菜单上，执行前先把焦点和选区还给输入框。
 * 富文本编辑器的粘贴先派发 paste 事件，让编辑器按自己的规则处理（Markdown、链接等）。
 */
function editItems(el: HTMLElement, services: TargetServices | null): MenuInput[] {
  const field = el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement ? el : null;
  const readOnly = field ? field.readOnly || field.disabled : false;
  const start = field?.selectionStart ?? 0;
  const end = field?.selectionEnd ?? 0;
  const selection = window.getSelection();
  const range = !field && selection && selection.rangeCount > 0 && el.contains(selection.anchorNode) ? selection.getRangeAt(0).cloneRange() : null;
  const text = field ? field.value.slice(start, end) : range?.toString() ?? "";
  const hasValue = field ? field.value.length > 0 : Boolean(el.textContent);

  const restore = () => {
    el.focus();
    if (field) field.setSelectionRange(start, end);
    else if (range) {
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(range);
    }
  };
  const exec = (command: string, value?: string) => () => {
    restore();
    document.execCommand(command, false, value);
  };

  return [
    !readOnly && { label: "撤销", icon: <Undo2 size={14} />, onSelect: exec("undo") },
    !readOnly && { label: "重做", icon: <Redo2 size={14} />, onSelect: exec("redo") },
    "separator",
    !readOnly && {
      label: "剪切",
      icon: <Scissors size={14} />,
      disabled: !text,
      onSelect: guarded(async () => {
        await copyText(text);
        exec("delete")();
      }),
    },
    { label: "复制", icon: <Copy size={14} />, disabled: !text, onSelect: guarded(() => copyText(text)) },
    !readOnly && {
      label: "粘贴",
      icon: <ClipboardPaste size={14} />,
      onSelect: guarded(async () => {
        const value = await api.clipboardReadText().catch(() => null);
        if (!value) return toast("剪贴板中没有文字", true);
        restore();
        if (!field) {
          try {
            const data = new DataTransfer();
            data.setData("text/plain", value);
            const event = new ClipboardEvent("paste", { clipboardData: data, bubbles: true, cancelable: true });
            if (!el.dispatchEvent(event)) return;
          } catch {
            // 不支持构造粘贴事件时直接插入文字
          }
        }
        document.execCommand("insertText", false, value);
      }),
    },
    "separator",
    {
      label: "全选",
      icon: <TextSelect size={14} />,
      disabled: !hasValue,
      onSelect: () => {
        el.focus();
        if (field) field.select();
        else document.execCommand("selectAll");
      },
    },
    ...(text.trim() && services ? ["separator" as const, ...selectionItems(text.trim(), services).slice(1)] : []),
  ];
}
