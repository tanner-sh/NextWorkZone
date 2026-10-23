import { createContext, useContext, useMemo, useState, type ReactNode } from "react";

export type PageId = "home" | "todos" | "notes" | "kb" | "jira" | "activity" | "weekly" | "wiki" | "gitlab" | "stats" | "tools" | "settings" | "search";

export const PAGE_IDS: PageId[] = ["home", "todos", "notes", "kb", "jira", "activity", "weekly", "wiki", "gitlab", "stats", "tools", "settings", "search"];

/** 跳转时附带的目标，例如打开某个 Jira 问题或 GitLab 项目。 */
export interface NavTarget {
  page: PageId;
  issueKey?: string;
  projectId?: number;
  /** 笔记或知识库页面 */
  docId?: string;
  /** 待办 */
  todoId?: string;
  /** 在问题列表中执行的 JQL（例如“查看全部相似问题”） */
  jql?: string;
  /** Wiki 页面 id（或页面地址） */
  wikiPage?: string;
  /** 在 Wiki 中搜索的文字 */
  wikiSearch?: string;
  /** 页面内的锚点（标题 id） */
  anchor?: string;
  /** GitLab 项目路径（例如 group/project），找不到 id 时使用 */
  projectPath?: string;
  /** GitLab 合并请求编号（项目内的 !iid），与 projectId 或 projectPath 一起使用 */
  mrIid?: number;
  /** GitLab 分支（或 tree/ 之后的路径，打开时按项目中已有的分支确定分支名），与 projectId 或 projectPath 一起使用 */
  gitRef?: string;
  /** GitLab 提交，与 projectId 或 projectPath 一起使用 */
  commitSha?: string;
  /** 工具 id（见 tools/registry），与 page: "tools" 一起使用 */
  tool?: string;
  /** 工具页面中的标签，例如 settings */
  toolTab?: string;
  /** 工具页面中的搜索文字（例如在剪贴板历史中查找） */
  toolQuery?: string;
  /** 搜索页的搜索文字 */
  searchQuery?: string;
  /** 搜索页的范围，见 SearchPage */
  searchScope?: string;
}

interface NavContextValue {
  current: NavTarget;
  navigate: (target: NavTarget) => void;
}

const NavContext = createContext<NavContextValue | null>(null);
const STORAGE_KEY = "nextworkzone.lastPage";
const TOOL_KEY = "nextworkzone.lastTool";

function initialTarget(): NavTarget {
  try {
    const saved = localStorage.getItem(STORAGE_KEY) as PageId | null;
    // 搜索页需要搜索文字，启动时不恢复
    if (saved && PAGE_IDS.includes(saved) && saved !== "search") return saved === "tools" ? { page: saved, tool: localStorage.getItem(TOOL_KEY) ?? undefined } : { page: saved };
  } catch {
    // 本地存储不可用时使用默认页面
  }
  return { page: "home" };
}

export function NavProvider({ children }: { children: ReactNode }) {
  const [current, setCurrent] = useState<NavTarget>(initialTarget);

  const value = useMemo<NavContextValue>(
    () => ({
      current,
      navigate: (target) => {
        setCurrent(target);
        try {
          localStorage.setItem(STORAGE_KEY, target.page);
          if (target.tool) localStorage.setItem(TOOL_KEY, target.tool);
        } catch {
          // 忽略
        }
      },
    }),
    [current],
  );

  return <NavContext.Provider value={value}>{children}</NavContext.Provider>;
}

export function useNav(): NavContextValue {
  const value = useContext(NavContext);
  if (!value) throw new Error("useNav 必须在 NavProvider 内使用");
  return value;
}
