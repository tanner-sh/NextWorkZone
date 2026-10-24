import { lazy, Suspense, useCallback, useEffect, useLayoutEffect, useRef, useState, type ComponentType, type ReactNode } from "react";
import { BarChart3, Bell, BookOpen, BookText, CheckSquare, CircleDot, FolderGit2, LayoutDashboard, NotebookPen, NotepadText, Search, Settings2, type LucideProps } from "lucide-react";
import { CommandPalette } from "./components/CommandPalette";
import { ErrorBoundary } from "./components/ErrorBoundary";
import { MenuHost } from "./components/MenuHost";
import { listen } from "@tauri-apps/api/event";
import { api, TRAY_EVENT } from "./api";
import { countMyIssues } from "./lib/notify";
import { ACTIVITY_INTERVAL_MS, pollActivity, useActivityFeed } from "./lib/activity";
import { checkReminders, useReminders } from "./lib/reminders";
import { refreshInbox, useInbox } from "./lib/inbox";
import { useWorkspaceRefresh, workspaceChanged } from "./lib/workspace";
import { HomePage } from "./pages/HomePage";
import { QuickTodo } from "./pages/workspace/QuickTodo";
import { Toasts } from "./components/Toast";
import { FileDropLayer } from "./components/FileDropLayer";
import { NavProvider, PAGE_IDS, PageActiveContext, useNav, type PageId } from "./state/nav";
import { openLink } from "./lib/links";
import { TOOLS, toolById, useHiddenTools } from "./tools/registry";
import { SettingsProvider, useSettings } from "./state/settings";

// 首页之外的页面在第一次打开时才加载，编辑器、代码高亮等大依赖随页面一起按需加载
const page = <K extends string>(load: () => Promise<Record<K, ComponentType>>, name: K) => lazy(() => load().then((m) => ({ default: m[name] })));
const ActivityPage = page(() => import("./pages/jira/ActivityPage"), "ActivityPage");
const StatsPage = page(() => import("./pages/jira/StatsPage"), "StatsPage");
const KnowledgePage = page(() => import("./pages/workspace/KnowledgePage"), "KnowledgePage");
const NotesPage = page(() => import("./pages/workspace/NotesPage"), "NotesPage");
const TodoPage = page(() => import("./pages/workspace/TodoPage"), "TodoPage");
const SettingsPage = page(() => import("./pages/SettingsPage"), "SettingsPage");
const GitlabPage = page(() => import("./pages/gitlab/GitlabPage"), "GitlabPage");
const JiraPage = page(() => import("./pages/jira/JiraPage"), "JiraPage");
const WeeklyPage = page(() => import("./pages/weekly/WeeklyPage"), "WeeklyPage");
const WikiPage = page(() => import("./pages/wiki/WikiPage"), "WikiPage");
const SearchPage = page(() => import("./pages/SearchPage"), "SearchPage");

/** 切走后只隐藏、不卸载的页面：回来时列表的滚动位置、选中项、搜索条件和展开状态都还在。其余页面每次打开时重新加载。 */
const KEEP_ALIVE: Partial<Record<PageId, ComponentType>> = { todos: TodoPage, notes: NotesPage, kb: KnowledgePage, jira: JiraPage, wiki: WikiPage, gitlab: GitlabPage };

type NavEntry = { id: PageId; label: string; icon: ComponentType<LucideProps> };

const NAV_GROUPS: { label: string; items: NavEntry[] }[] = [
  {
    label: "工作空间",
    items: [
      { id: "home", label: "今天", icon: LayoutDashboard },
      { id: "todos", label: "待办", icon: CheckSquare },
      { id: "notes", label: "笔记", icon: NotepadText },
      { id: "kb", label: "知识库", icon: BookOpen },
    ],
  },
  {
    label: "集成",
    items: [
      { id: "jira", label: "Jira", icon: CircleDot },
      { id: "wiki", label: "Wiki", icon: BookText },
      { id: "gitlab", label: "GitLab", icon: FolderGit2 },
    ],
  },
  {
    // 回看发生了什么：动态、周报、统计（需要处理的事在今天页）
    label: "回顾",
    items: [
      { id: "activity", label: "动态", icon: Bell },
      { id: "weekly", label: "周报", icon: NotebookPen },
      { id: "stats", label: "统计", icon: BarChart3 },
    ],
  },
];
const NAV_ORDER: PageId[] = NAV_GROUPS.flatMap((g) => g.items.map((i) => i.id));

export function App() {
  return (
    <SettingsProvider>
      <NavProvider>
        <MenuHost>
          <Shell />
        </MenuHost>
      </NavProvider>
    </SettingsProvider>
  );
}

function Shell() {
  const { current, navigate } = useNav();
  const { isReady, baseUrl } = useSettings();
  const [hiddenTools] = useHiddenTools();
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [quickTodo, setQuickTodo] = useState(false);
  const [issueCount, setIssueCount] = useState<number | null>(null);
  // 打开过的保留页面，按第一次打开的顺序
  const [kept, setKept] = useState<PageId[]>([]);
  if (KEEP_ALIVE[current.page] && !kept.includes(current.page)) setKept([...kept, current.page]);

  // ⌘K 打开全局搜索，⌘1–⌘9、⌘0 切换页面
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!(e.metaKey || e.ctrlKey)) return;
      if (e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen((open) => !open);
        return;
      }
      // ⌘⇧N 随时记一条待办
      if (e.shiftKey && e.key.toLowerCase() === "n") {
        e.preventDefault();
        setQuickTodo(true);
        return;
      }
      if (e.key === ",") {
        e.preventDefault();
        navigate({ page: "settings" });
        return;
      }
      // ⌘0 是第十个
      const index = e.key === "0" ? 9 : Number(e.key) - 1;
      if (!e.shiftKey && !e.altKey && index >= 0 && index < NAV_ORDER.length) {
        e.preventDefault();
        navigate({ page: NAV_ORDER[index] });
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [navigate]);

  useEffect(() => {
    void refreshInbox().catch(() => {});
  }, []);

  // 托盘菜单：后端已显示窗口，这里打开对应的页面或对话框
  useEffect(() => {
    const unlisten = listen<string>(TRAY_EVENT, ({ payload }) => {
      if (payload === "quick-todo") setQuickTodo(true);
      else if (payload === "search") setPaletteOpen(true);
      else if (payload.startsWith("page:")) {
        const page = payload.slice(5) as PageId;
        if (PAGE_IDS.includes(page)) navigate({ page });
      } else if (payload.startsWith("tool:")) {
        // tool:<工具>[:<标签>]
        const [tool, toolTab] = payload.slice(5).split(":");
        if (toolById(tool)) navigate({ page: "tools", tool, toolTab });
      } else if (payload.startsWith("url:")) {
        void openLink(payload.slice(4), baseUrl, navigate);
      }
    });
    return () => void unlisten.then((fn) => fn());
  }, [navigate, baseUrl]);

  // 定期检查 Jira 和 Wiki 动态（有新动态时通知），并更新侧边栏的问题数、同步分配给我的问题为待办
  const jiraReady = isReady("jira");
  const wikiReady = isReady("confluence");
  const activity = useActivityFeed();
  const inbox = useInbox();
  // 未安排日期的待办（新分配的 Jira 问题也在这里），显示在侧边栏提醒去安排
  const [unscheduled, setUnscheduled] = useState<number | null>(null);
  const loadUnscheduled = useCallback(() => {
    api.wsTodos().then((list) => setUnscheduled(list.filter((t) => !t.done && t.due === null).length), () => {});
  }, []);
  useEffect(loadUnscheduled, [loadUnscheduled]);
  useWorkspaceRefresh(loadUnscheduled);
  const counts: Partial<Record<PageId, number | null | undefined>> = { home: inbox?.items.length, todos: unscheduled, jira: issueCount, activity: activity?.unread };
  const reminders = useReminders();
  const overdue = reminders?.items.filter((r) => r.kind === "overdue" || r.kind === "today").length ?? 0;
  useEffect(() => {
    if (!jiraReady && !wikiReady) return;
    let rounds = 0;
    const run = () => {
      // 新的动态也会进入今天页的“需要处理”
      void pollActivity()
        .catch(() => {})
        .finally(() => void refreshInbox().catch(() => {}));
      // 问题数和待办不需要那么频繁，大约每 9 分钟一次
      if (jiraReady && rounds++ % 3 === 0) {
        void countMyIssues().then(setIssueCount, () => {});
        void checkReminders().catch(() => {});
        api.wsRefreshJiraTodos().then((r) => r && r.added + r.completed + r.reopened > 0 && workspaceChanged(), () => {});
      }
    };
    run();
    const timer = setInterval(run, ACTIVITY_INTERVAL_MS);
    return () => clearInterval(timer);
  }, [jiraReady, wikiReady]);

  return (
    <div className="shell">
      <nav className="sidebar">
        <div className="sidebar-drag" data-tauri-drag-region />
        <div className="brand" data-tauri-drag-region>
          <span className="brand-mark">
            <LayoutDashboard size={13} strokeWidth={2.5} />
          </span>
          NextWorkZone
        </div>
        <button className="search-trigger" onClick={() => setPaletteOpen(true)} title="搜索问题、项目、文档，或跳转到页面">
          <Search size={14} />
          <span>搜索</span>
          <kbd>⌘K</kbd>
        </button>
        {NAV_GROUPS.map((group) => (
          <div className="nav-group" key={group.label}>
            <div className="nav-group-label">{group.label}</div>
            {group.items.map((item) => (
              <NavButton
                key={item.id}
                {...item}
                shortcut={NAV_ORDER.indexOf(item.id) < 10 ? String((NAV_ORDER.indexOf(item.id) + 1) % 10) : undefined}
                active={current.page === item.id}
                count={counts[item.id] || null}
                alert={item.id === "jira" && overdue > 0 ? `${overdue} 个问题已逾期或今天到期` : undefined}
                onClick={() => navigate({ page: item.id })}
              />
            ))}
          </div>
        ))}
        {TOOLS.some((t) => !hiddenTools.includes(t.id)) && (
          <div className="nav-group">
            <div className="nav-group-label">工具</div>
            {TOOLS.filter((t) => !hiddenTools.includes(t.id)).map((tool) => (
              <NavButton key={tool.id} id="tools" label={tool.name} icon={tool.icon} active={current.page === "tools" && (current.tool ?? TOOLS[0].id) === tool.id} onClick={() => navigate({ page: "tools", tool: tool.id })} />
            ))}
          </div>
        )}
        <div className="sidebar-spacer" />
        <NavButton id="settings" label="设置" icon={Settings2} shortcut="," active={current.page === "settings"} onClick={() => navigate({ page: "settings" })} />
      </nav>
      <div className="main">
        {/* 没有顶部栏：内容区顶端留一条可以拖动窗口的区域 */}
        <div className="main-drag" data-tauri-drag-region />
        <main className="content">
          {kept.map((id) => {
            const Page = KEEP_ALIVE[id]!;
            return (
              <PageSlot key={id} active={current.page === id}>
                <Page />
              </PageSlot>
            );
          })}
          {!KEEP_ALIVE[current.page] && (
            <ErrorBoundary resetKey={current.page}>
              <Suspense fallback={null}>
                {current.page === "home" && <HomePage />}
                {current.page === "activity" && <ActivityPage />}
                {current.page === "weekly" && <WeeklyPage />}
                {current.page === "stats" && <StatsPage />}
                {current.page === "tools" && <ToolHost tool={current.tool} tab={current.toolTab} />}
                {current.page === "settings" && <SettingsPage />}
                {current.page === "search" && <SearchPage />}
              </Suspense>
            </ErrorBoundary>
          )}
        </main>
      </div>
      {paletteOpen && <CommandPalette onClose={() => setPaletteOpen(false)} onQuickTodo={() => setQuickTodo(true)} />}
      {quickTodo && <QuickTodo onClose={() => setQuickTodo(false)} />}
      <FileDropLayer />
      <Toasts />
    </div>
  );
}

/**
 * 保留的页面。隐藏时页面中的滚动区域不一定保留位置，所以随时记下各区域的位置，再次显示时恢复。
 * 隐藏时移走焦点，避免按键输入到看不见的输入框。
 */
function PageSlot({ active, children }: { active: boolean; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const activeRef = useRef(active);
  const scrolls = useRef(new Map<Element, number>());

  useEffect(() => {
    const slot = ref.current!;
    // 滚动事件不冒泡，在捕获阶段统一记录；隐藏后浏览器把位置归零时触发的事件不记
    const onScroll = (e: Event) => {
      if (activeRef.current && e.target instanceof Element) scrolls.current.set(e.target, e.target.scrollTop);
    };
    slot.addEventListener("scroll", onScroll, true);
    return () => slot.removeEventListener("scroll", onScroll, true);
  }, []);

  useLayoutEffect(() => {
    activeRef.current = active;
    const slot = ref.current!;
    if (!active) {
      if (document.activeElement instanceof HTMLElement && slot.contains(document.activeElement)) document.activeElement.blur();
      return;
    }
    for (const [el, top] of scrolls.current) {
      if (!el.isConnected) scrolls.current.delete(el);
      else if (el.scrollTop !== top) el.scrollTop = top;
    }
  }, [active]);

  return (
    <div ref={ref} className="page-slot" hidden={!active}>
      <PageActiveContext.Provider value={active}>
        {/* 切回这个页面时清除错误 */}
        <ErrorBoundary resetKey={String(active)}>
          <Suspense fallback={null}>{children}</Suspense>
        </ErrorBoundary>
      </PageActiveContext.Provider>
    </div>
  );
}

/** 工具页面：按注册表找到对应的工具。 */
function ToolHost({ tool, tab }: { tool?: string; tab?: string }) {
  const def = toolById(tool) ?? TOOLS[0];
  return <def.Page key={def.id} tab={tab} />;
}

function NavButton(props: { id: PageId; label: string; icon: ComponentType<LucideProps>; shortcut?: string; active: boolean; count?: number | null; alert?: string; onClick: () => void }) {
  const Icon = props.icon;
  return (
    <button className={`nav-item${props.active ? " active" : ""}`} onClick={props.onClick} title={`${props.label}${props.shortcut ? `（⌘${props.shortcut}）` : ""}${props.alert ? `\n${props.alert}` : ""}`}>
      <Icon size={16} strokeWidth={2} />
      {props.label}
      {props.count ? <span className={`nav-count${props.alert ? " alert" : ""}`}>{props.count}</span> : null}
    </button>
  );
}
