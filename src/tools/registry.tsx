// 小工具的注册表。新增工具时在 TOOLS 中加一项：侧边栏的“工具”分组、⌘K 搜索、设置页的“工具”卡片都据此生成。
import { useEffect, useState, type ComponentType } from "react";
import { ClipboardList, type LucideIcon } from "lucide-react";
import { api } from "../api";
import { ClipboardPage } from "../pages/tools/clipboard/ClipboardPage";
import { ClipboardSummary } from "../pages/tools/clipboard/ClipboardSettings";

export interface ToolDef {
  id: string;
  name: string;
  icon: LucideIcon;
  /** 一句话说明，显示在设置页和搜索结果中 */
  description: string;
  /** ⌘K 搜索的关键词（含拼音首字母） */
  keywords: string;
  /** 工具页面；`tab` 为要打开的标签（例如 settings） */
  Page: ComponentType<{ tab?: string }>;
  /** 设置页“工具”卡片中的简要设置（开关、快捷键） */
  Summary?: ComponentType;
}

export const TOOLS: ToolDef[] = [
  {
    id: "clipboard",
    name: "剪贴板",
    icon: ClipboardList,
    description: "记录复制过的文字、图片和文件，按快捷键随时搜索、粘贴；常用内容可以置顶。",
    keywords: "clipboard paste 剪贴板 粘贴 复制 历史 jtb",
    Page: ClipboardPage,
    Summary: ClipboardSummary,
  },
];

export const toolById = (id: string | undefined) => TOOLS.find((t) => t.id === id);

const HIDDEN_EVENT = "nextworkzone-tools-hidden";
let hiddenCache: string[] | null = null;

/** 不在侧边栏显示的工具。 */
export function useHiddenTools(): [string[], (hidden: string[]) => Promise<void>] {
  const [hidden, setHidden] = useState<string[]>(hiddenCache ?? []);
  useEffect(() => {
    const update = () => setHidden(hiddenCache ?? []);
    window.addEventListener(HIDDEN_EVENT, update);
    if (hiddenCache === null) {
      api.toolsHidden().then((h) => {
        hiddenCache = h;
        window.dispatchEvent(new Event(HIDDEN_EVENT));
      }, () => {});
    }
    return () => window.removeEventListener(HIDDEN_EVENT, update);
  }, []);
  const save = async (next: string[]) => {
    hiddenCache = await api.toolsSetHidden(next);
    window.dispatchEvent(new Event(HIDDEN_EVENT));
  };
  return [hidden, save];
}
