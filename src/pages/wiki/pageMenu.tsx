// Wiki 页面和空间的右键菜单：页面树、最近、收藏、搜索结果、子页面、正文中的页面链接等处共用。
import { openUrl } from "@tauri-apps/plugin-opener";
import { BookOpen, BookText, CheckSquare, Copy, ExternalLink, FilePlus2, Link, NotepadText, RefreshCw, Star, StarOff } from "lucide-react";
import { api } from "../../api";
import type { MenuInput } from "../../components/ContextMenu";
import { guarded, toast } from "../../components/Toast";
import { copyText } from "../../lib/clipboard";
import { loadFavorites, toggleFavorite } from "../../lib/wiki";
import { workspaceChanged } from "../../lib/workspace";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { wikiToPage } from "../workspace/kbImport";

/** 菜单针对的页面：标题和空间名未知时（例如正文中的链接）按需查询。 */
export interface WikiPageTarget {
  id: string;
  title?: string;
  /** 空间名称（收藏列表显示用） */
  space?: string;
}

export interface WikiPageMenuOptions {
  /** 当前正在查看这个页面（不显示“打开”） */
  current?: boolean;
  /** 提供时显示“新建子页面” */
  onNewChild?: () => void;
}

export function wikiPageUrl(base: string, id: string) {
  return `${base}/pages/viewpage.action?pageId=${id}`;
}

const copy = (text: () => string | Promise<string>) =>
  guarded(async () => {
    await copyText(await text());
    toast("已复制");
  });

export function useWikiPageMenu() {
  const { baseUrl } = useSettings();
  const { navigate } = useNav();
  const base = baseUrl("confluence");

  const pageMenu = (target: WikiPageTarget, options: WikiPageMenuOptions = {}): MenuInput[] => {
    const { id } = target;
    const url = wikiPageUrl(base, id);
    let pending: Promise<{ title: string; space: string }> | null = target.title && target.space !== undefined ? Promise.resolve({ title: target.title, space: target.space }) : null;
    const info = () => (pending ??= api.wikiPage(id).then((p) => ({ title: p.title, space: p.spaceName })));
    const title = async () => target.title ?? (await info()).title;
    const favorite = loadFavorites().some((f) => f.id === id);
    return [
      !options.current && { label: "打开", icon: <BookText size={14} />, onSelect: () => navigate({ page: "wiki", wikiPage: id }) },
      {
        label: favorite ? "取消收藏" : "收藏",
        icon: favorite ? <StarOff size={14} /> : <Star size={14} />,
        onSelect: guarded(async () => toggleFavorite({ id, ...(await info()) })),
      },
      options.onNewChild && { label: "新建子页面…", icon: <FilePlus2 size={14} />, onSelect: options.onNewChild },
      "separator",
      { label: "复制链接", icon: <Link size={14} />, onSelect: copy(() => url) },
      { label: "复制标题", icon: <Copy size={14} />, onSelect: copy(title) },
      { label: "复制为 Markdown 链接", onSelect: copy(async () => `[${await title()}](${url})`) },
      "separator",
      {
        label: "添加待办",
        icon: <CheckSquare size={14} />,
        onSelect: guarded(async () => {
          const t = await title();
          await api.wsSaveTodo({ title: t, refSystem: "wiki", refKey: id, refTitle: t });
          workspaceChanged();
          toast("已添加待办");
        }),
      },
      {
        label: "写笔记",
        icon: <NotepadText size={14} />,
        onSelect: guarded(async () => {
          const t = await title();
          const doc = await api.wsSaveDoc({ kind: "note", title: t, content: `[${t}](${url})\n\n` });
          workspaceChanged();
          navigate({ page: "notes", docId: doc.id });
        }),
      },
      { label: "剪藏到知识库", icon: <BookOpen size={14} />, onSelect: guarded(async () => navigate({ page: "kb", docId: (await wikiToPage(id, base)).id })) },
      "separator",
      { label: "在浏览器中打开", icon: <ExternalLink size={14} />, onSelect: guarded(() => openUrl(url)) },
    ];
  };

  const spaceMenu = (space: { key: string; name: string; homepageId: string | null }, options: { onCreate?: () => void; onRefresh?: () => void } = {}): MenuInput[] => {
    const url = `${base}/display/${encodeURIComponent(space.key)}`;
    return [
      space.homepageId && { label: "打开空间首页", icon: <BookText size={14} />, onSelect: () => navigate({ page: "wiki", wikiPage: space.homepageId! }) },
      options.onCreate && { label: "在空间顶层新建页面…", icon: <FilePlus2 size={14} />, onSelect: options.onCreate },
      options.onRefresh && { label: "刷新页面树", icon: <RefreshCw size={14} />, onSelect: options.onRefresh },
      "separator",
      { label: "复制空间键", icon: <Copy size={14} />, onSelect: copy(() => space.key) },
      { label: "复制空间名称", onSelect: copy(() => space.name) },
      { label: "复制链接", icon: <Link size={14} />, onSelect: copy(() => url) },
      "separator",
      { label: "在浏览器中打开", icon: <ExternalLink size={14} />, onSelect: guarded(() => openUrl(url)) },
    ];
  };

  return { pageMenu, spaceMenu };
}
