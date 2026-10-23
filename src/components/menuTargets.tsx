// 按右键的目标生成菜单项：输入框、选中的文字、链接、图片、代码块。
// 主窗口的 MenuHost 在此基础上加入问题、Wiki 页面等对象的菜单；其他窗口只用 BasicMenuHost，不加载那些代码。
import { useEffect, useRef, type ReactNode } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { CheckSquare, ClipboardPaste, Code2, Copy, ExternalLink, Image, Link, Maximize2, Redo2, Scissors, Search, TextSelect, Undo2 } from "lucide-react";
import { api } from "../api";
import { ATTACHMENT_PATH } from "../lib/asset";
import { copyText } from "../lib/clipboard";
import type { routeUrl } from "../lib/links";
import { workspaceChanged } from "../lib/workspace";
import { useContextMenu, type MenuInput } from "./ContextMenu";
import type { MenuServices } from "./MenuHost";
import { guarded, toast } from "./Toast";

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

// ---------- 按目标生成 ----------

export interface TargetServices {
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

export function targetItems(target: Element, services: TargetServices | null): MenuInput[] {
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

/** 选中的文字：复制，搜索，记为待办（第一行作标题，其余作备注）；是问题键时附上问题菜单。 */
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
        await api.wsSaveTodo({ title: single.slice(0, 200), notes: text.split("\n").slice(1).join("\n").trim() });
        workspaceChanged();
        toast("已添加待办");
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
