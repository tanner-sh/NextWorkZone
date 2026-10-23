import { useCallback, useEffect, useState } from "react";
import { AlarmClock, BellOff, BookText, CalendarDays, Check, CheckSquare, ChevronDown, ChevronRight, CircleDot, Clock3, GitPullRequest, Inbox, Plus, RefreshCw } from "lucide-react";
import { api, errorMessage, type InboxItem, type Todo } from "../../api";
import { ErrorBox, Skeleton } from "../../components/common";
import { useContextMenu, type MenuInput } from "../../components/ContextMenu";
import { guarded } from "../../components/Toast";
import { formatTime } from "../../lib/format";
import { handleItem, itemDetail, itemTarget, itemToTodo, refreshInbox, snoozeItem, useInbox } from "../../lib/inbox";
import { openLink } from "../../lib/links";
import { addDays, formatDay, formatMoment, momentPresets, today, useWorkspaceRefresh, workspaceChanged } from "../../lib/workspace";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { todoInput } from "./todoMenu";

/** 拖动时携带的数据类型：收件箱条目或未安排的待办。 */
const DRAG_ITEM = "application/x-nextworkzone-inbox";
const DRAG_TODO = "application/x-nextworkzone-todo";

/**
 * 收件箱：需要我处理的事（记下的内容、动态、到期问题、合并请求）和未安排日期的待办；
 * 右侧是今天的计划——把条目拖过去（或点“今天”）就加入今天的待办。
 */
export function InboxPage() {
  const { navigate } = useNav();
  const { baseUrl } = useSettings();
  const view = useInbox();
  const contextMenu = useContextMenu();
  const [todos, setTodos] = useState<Todo[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [showSnoozed, setShowSnoozed] = useState(false);
  const [draft, setDraft] = useState("");
  const day = today();

  const refresh = useCallback(async () => {
    setLoading(true);
    try {
      await refreshInbox();
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setLoading(false);
    }
  }, []);
  const loadTodos = useCallback(() => {
    api.wsTodos().then(setTodos, () => setTodos([]));
  }, []);
  useEffect(() => {
    void refresh();
    loadTodos();
  }, [refresh, loadTodos]);
  useWorkspaceRefresh(loadTodos);

  const run = (task: () => Promise<unknown>) =>
    void task().catch((e) => {
      setError(errorMessage(e));
      void refreshInbox().catch(() => {});
    });

  const open = (item: InboxItem) => {
    const target = itemTarget(item);
    if (target) navigate(target);
    else if (item.url) void openLink(item.url, baseUrl, navigate);
  };
  const toTodo = (item: InboxItem, due: string | null) => run(() => itemToTodo(item, due, todos ?? []).then(loadTodos));
  const planTodo = (todo: Todo, due: string | null) =>
    run(async () => {
      await api.wsSaveTodo(todoInput(todo, { due }));
      workspaceChanged();
    });

  const snoozeMenu = (item: InboxItem): MenuInput[] => [
    ...momentPresets().map((p) => ({ label: p.label, icon: <AlarmClock size={14} />, onSelect: () => run(() => snoozeItem(item, p.at)) })),
  ];
  const moreMenu = (item: InboxItem): MenuInput[] => [
    { label: "转为待办：今天", icon: <CalendarDays size={14} />, onSelect: () => toTodo(item, day) },
    { label: "转为待办：明天", icon: <CalendarDays size={14} />, onSelect: () => toTodo(item, addDays(day, 1)) },
    { label: "转为待办：不设日期", icon: <CheckSquare size={14} />, onSelect: () => toTodo(item, null) },
    "separator",
    { label: "稍后提醒", icon: <AlarmClock size={14} />, children: snoozeMenu(item) },
    { label: item.source === "capture" ? "删除" : "忽略", icon: <Check size={14} />, onSelect: () => run(() => handleItem(item)) },
  ];

  const add = guarded(async () => {
    const text = draft.trim();
    if (!text) return;
    // 粘贴的是链接时同时记为链接，方便之后打开
    const url = /^https?:\/\/\S+$/.test(text) ? text : null;
    await api.wsCapture(text, "", url);
    setDraft("");
    await refreshInbox();
  });

  const items = view?.items ?? [];
  const snoozed = view?.snoozed ?? [];
  const unscheduled = (todos ?? []).filter((t) => !t.done && t.due === null).sort((a, b) => b.priority - a.priority || a.sort - b.sort);
  const planned = (todos ?? []).filter((t) => !t.done && t.due !== null && t.due <= day).sort((a, b) => (a.due ?? "").localeCompare(b.due ?? "") || b.priority - a.priority || a.sort - b.sort);

  return (
    <section className="page wide inbox-page">
      <header className="page-header">
        <div>
          <h1>
            收件箱 {items.length > 0 && <span className="count">{items.length}</span>}
          </h1>
          <p className="muted small">需要处理的事都在这里：处理完、转为待办，或者稍后再提醒。把条目拖到右侧，就加入今天的计划。</p>
        </div>
        <button className="btn subtle icon" title="刷新" onClick={refresh} disabled={loading}>
          <RefreshCw size={15} className={loading ? "spin" : ""} />
        </button>
      </header>

      <div className="inbox-layout">
        <div className="inbox-main">
          <div className="input-icon quick-add">
            <Plus size={15} />
            <input
              value={draft}
              placeholder="记下要处理的事或链接，回车保存（任何应用中按快速记录快捷键也可以）"
              onChange={(e) => setDraft(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.nativeEvent.isComposing) {
                  e.preventDefault();
                  add();
                }
              }}
            />
          </div>
          {error && <ErrorBox message={error} onRetry={refresh} />}
          {view?.notes.map((n) => (
            <p key={n} className="notice warn small">
              {n}
            </p>
          ))}
          {!view && !error && <Skeleton lines={6} height={18} />}

          <ul className="inbox-list">
            {items.map((item) => (
              <InboxRow
                key={item.id}
                item={item}
                menuOpen={contextMenu.target === item.id}
                onOpen={() => open(item)}
                onToday={() => toTodo(item, day)}
                onDone={() => run(() => handleItem(item))}
                onSnooze={(e) => contextMenu.open(e, snoozeMenu(item), item.id)}
                onMenu={(e) => contextMenu.open(e, moreMenu(item), item.id)}
              />
            ))}
            {view && items.length === 0 && (
              <li className="empty-center inbox-empty">
                <Inbox size={26} className="muted" />
                <div className="muted">没有需要处理的事</div>
              </li>
            )}
          </ul>

          {snoozed.length > 0 && (
            <div className="inbox-section">
              <button className="section-toggle" onClick={() => setShowSnoozed((v) => !v)}>
                {showSnoozed ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
                稍后提醒 <span className="count">{snoozed.length}</span>
              </button>
              {showSnoozed && (
                <ul className="inbox-list">
                  {snoozed.map((item) => (
                    <li key={item.id} className="inbox-row snoozed">
                      <ItemIcon item={item} />
                      <div className="inbox-text">
                        <button className="link-plain ellipsis" onClick={() => open(item)}>
                          {item.title || "无标题"}
                        </button>
                        <span className="muted small">{item.snoozeUntil ? `${formatMoment(item.snoozeUntil)} 提醒` : ""}</span>
                      </div>
                      <button className="btn subtle small-btn" onClick={() => run(() => snoozeItem(item, null))}>
                        <BellOff size={13} />
                        取消稍后
                      </button>
                    </li>
                  ))}
                </ul>
              )}
            </div>
          )}

          {unscheduled.length > 0 && (
            <div className="inbox-section">
              <h2 className="section-title">
                未安排的待办 <span className="count">{unscheduled.length}</span>
              </h2>
              <ul className="inbox-list">
                {unscheduled.map((todo) => (
                  <li key={todo.id} className="inbox-row" draggable onDragStart={(e) => e.dataTransfer.setData(DRAG_TODO, todo.id)}>
                    <button className={`check prio-${todo.priority}`} onClick={() => run(async () => (await api.wsSetTodoDone(todo.id, true), workspaceChanged()))} aria-label="完成">
                      <Check size={11} strokeWidth={3} className="check-hover" />
                    </button>
                    <div className="inbox-text">
                      <button className="link-plain ellipsis" onClick={() => navigate({ page: "todos", todoId: todo.id })}>
                        {todo.title || "无标题"}
                      </button>
                      {todo.refKey && todo.refSystem === "jira" && <span className="muted small">{todo.refKey}</span>}
                    </div>
                    <span className="row-actions">
                      <button className="btn small-btn" onClick={() => planTodo(todo, day)}>
                        今天
                      </button>
                      <button className="btn subtle small-btn" onClick={() => planTodo(todo, addDays(day, 1))}>
                        明天
                      </button>
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>

        <TodayPlan
          planned={planned}
          day={day}
          onDropItem={(id) => {
            const item = items.find((i) => i.id === id);
            if (item) toTodo(item, day);
          }}
          onDropTodo={(id) => {
            const todo = todos?.find((t) => t.id === id);
            if (todo) planTodo(todo, day);
          }}
          onRemove={(todo) => planTodo(todo, null)}
          onComplete={(todo) => run(async () => (await api.wsSetTodoDone(todo.id, true), workspaceChanged()))}
          onOpen={(todo) => navigate({ page: "todos", todoId: todo.id })}
        />
      </div>
      {contextMenu.menu}
    </section>
  );
}

function ItemIcon({ item }: { item: InboxItem }) {
  const Icon = item.source === "capture" ? Inbox : item.source === "due" ? Clock3 : item.source === "mr" ? GitPullRequest : item.system === "wiki" ? BookText : CircleDot;
  return (
    <span className={`inbox-icon source-${item.source}`}>
      <Icon size={14} />
    </span>
  );
}

function InboxRow(props: {
  item: InboxItem;
  menuOpen: boolean;
  onOpen: () => void;
  onToday: () => void;
  onDone: () => void;
  onSnooze: (e: React.MouseEvent) => void;
  onMenu: (e: React.MouseEvent) => void;
}) {
  const { item } = props;
  const openable = Boolean(itemTarget(item) || item.url);
  const detail = itemDetail(item);
  return (
    <li
      className={`inbox-row${props.menuOpen ? " menu-target" : ""}`}
      draggable
      onDragStart={(e) => e.dataTransfer.setData(DRAG_ITEM, item.id)}
      onContextMenu={props.onMenu}
    >
      <ItemIcon item={item} />
      <div className="inbox-text">
        {openable ? (
          <button className="link-plain ellipsis inbox-title" onClick={props.onOpen}>
            {item.title || "无标题"}
          </button>
        ) : (
          <span className="ellipsis inbox-title">{item.title || "无标题"}</span>
        )}
        {detail && <span className="muted small ellipsis">{detail}</span>}
      </div>
      {item.source !== "due" && <span className="muted small nowrap">{formatTime(new Date(item.at).toISOString())}</span>}
      <span className="row-actions">
        <button className="btn small-btn" title="转为今天的待办" onClick={props.onToday}>
          今天
        </button>
        <button className="btn subtle icon" title="稍后提醒" onClick={props.onSnooze}>
          <AlarmClock size={14} />
        </button>
        <button className="btn subtle icon" title={item.source === "capture" ? "完成并删除" : "已处理"} onClick={props.onDone}>
          <Check size={15} />
        </button>
        <button className="btn subtle icon" title="更多" onClick={props.onMenu}>
          <ChevronDown size={14} />
        </button>
      </span>
    </li>
  );
}

function TodayPlan(props: {
  planned: Todo[];
  day: string;
  onDropItem: (id: string) => void;
  onDropTodo: (id: string) => void;
  onRemove: (todo: Todo) => void;
  onComplete: (todo: Todo) => void;
  onOpen: (todo: Todo) => void;
}) {
  const [over, setOver] = useState(false);
  const [draft, setDraft] = useState("");
  const add = guarded(async () => {
    if (!draft.trim()) return;
    await api.wsSaveTodo({ title: draft.trim(), due: props.day });
    setDraft("");
    workspaceChanged();
  });
  return (
    <aside
      className={`card today-plan${over ? " drop-over" : ""}`}
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes(DRAG_ITEM) || e.dataTransfer.types.includes(DRAG_TODO)) {
          e.preventDefault();
          setOver(true);
        }
      }}
      onDragLeave={() => setOver(false)}
      onDrop={(e) => {
        e.preventDefault();
        setOver(false);
        const item = e.dataTransfer.getData(DRAG_ITEM);
        const todo = e.dataTransfer.getData(DRAG_TODO);
        if (item) props.onDropItem(item);
        else if (todo) props.onDropTodo(todo);
      }}
    >
      <div className="card-title">
        <h2>
          <CalendarDays size={16} className="muted" />
          今天的计划 {props.planned.length > 0 && <span className="count">{props.planned.length}</span>}
        </h2>
      </div>
      <ul className="home-list">
        {props.planned.map((t) => (
          <li key={t.id}>
            <div className="home-row">
              <button className={`check prio-${t.priority}`} onClick={() => props.onComplete(t)} aria-label="完成">
                <Check size={11} strokeWidth={3} className="check-hover" />
              </button>
              <button className="link-plain ellipsis grow" onClick={() => props.onOpen(t)}>
                {t.title || "无标题"}
              </button>
              {t.due && t.due < props.day && <span className="due-chip overdue">{formatDay(t.due)}</span>}
              <button className="btn subtle icon plan-remove" title="移出今天（改为未安排）" onClick={() => props.onRemove(t)}>
                <ChevronRight size={14} />
              </button>
            </div>
          </li>
        ))}
        {props.planned.length === 0 && <li className="muted small plan-empty">把左侧的条目拖到这里，或点“今天”</li>}
      </ul>
      <div className="input-icon quick-add">
        <Plus size={15} />
        <input
          value={draft}
          placeholder="添加今天的待办"
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.nativeEvent.isComposing) {
              e.preventDefault();
              add();
            }
          }}
        />
      </div>
    </aside>
  );
}
