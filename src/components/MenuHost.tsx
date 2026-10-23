// 全局右键菜单：替换 WebView 自带的菜单（只有“重新载入”），让应用内各处的右键行为一致。
//
// 规则：
// - 列表项等对象自己打开菜单（`menus.open` 或局部的 useContextMenu），调用 preventDefault 后这里不再处理；
// - 其余位置由这里按点击的目标生成：输入框（撤销、剪切、复制、粘贴、全选）、选中的文字、链接、图片、代码块；
// - 页面区域可以用 `contributeMenu` 附加本区域的操作（例如 Wiki 页面、问题详情）。
//   没有更具体的目标时这些操作直接列出，否则放在以区域命名的子菜单中；
// - 按住 ⌥ 右键仍显示系统菜单（调试时检查元素）。
import { createContext, useContext, useEffect, useRef, type ReactNode } from "react";
import { openLink, routeUrl } from "../lib/links";
import { useIssueMenu, type IssueMenuOptions, type IssueTarget } from "../pages/jira/issueMenu";
import { useWikiPageMenu, type WikiPageMenuOptions, type WikiPageTarget } from "../pages/wiki/pageMenu";
import { useNav } from "../state/nav";
import { useSettings } from "../state/settings";
import { useContextMenu, type MenuInput } from "./ContextMenu";
import { targetItems } from "./menuTargets";

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

export interface MenuServices {
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
