import { useCallback, useEffect, useState } from "react";
import { AlarmClock, BellOff, BookText, CalendarDays, Check, CheckCircle2, CheckSquare, ChevronDown, ChevronRight, CircleDot, Clock3, GitPullRequest, RefreshCw } from "lucide-react";
import { api, errorMessage, type InboxItem, type Todo } from "../../api";
import { Skeleton } from "../../components/common";
import { useContextMenu, type MenuInput } from "../../components/ContextMenu";
import { formatTime } from "../../lib/format";
import { handleItem, itemDetail, itemTarget, itemToTodo, refreshInbox, snoozeItem, useInbox } from "../../lib/inbox";
import { addDays, formatMoment, momentPresets, today, useWorkspaceRefresh } from "../../lib/workspace";
import { useNav } from "../../state/nav";

/**
 * 今天页的“需要处理”：需要我回应的动态、逾期或今天到期的问题、请我审核的合并请求。
 * 每条可以打开、标为已处理、转为待办或稍后提醒；处理之后有新变化时会再次出现。
 */
export function AttentionCard() {
  const { navigate } = useNav();
  const view = useInbox();
  const contextMenu = useContextMenu();
  const [todos, setTodos] = useState<Todo[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [showSnoozed, setShowSnoozed] = useState(false);
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
  };
  const toTodo = (item: InboxItem, due: string | null) => run(() => itemToTodo(item, due, todos ?? []).then(loadTodos));

  const snoozeMenu = (item: InboxItem): MenuInput[] => [
    ...momentPresets().map((p) => ({ label: p.label, icon: <AlarmClock size={14} />, onSelect: () => run(() => snoozeItem(item, p.at)) })),
  ];
  const moreMenu = (item: InboxItem): MenuInput[] => [
    { label: "转为待办：今天", icon: <CalendarDays size={14} />, onSelect: () => toTodo(item, day) },
    { label: "转为待办：明天", icon: <CalendarDays size={14} />, onSelect: () => toTodo(item, addDays(day, 1)) },
    { label: "转为待办：不设日期", icon: <CheckSquare size={14} />, onSelect: () => toTodo(item, null) },
    "separator",
    { label: "稍后提醒", icon: <AlarmClock size={14} />, children: snoozeMenu(item) },
    { label: "已处理", icon: <Check size={14} />, onSelect: () => run(() => handleItem(item)) },
  ];

  const items = view?.items ?? [];
  const snoozed = view?.snoozed ?? [];

  // 没有任何需要处理的事：只占一行，不占一整块
  if (view && items.length === 0 && snoozed.length === 0 && view.notes.length === 0 && !error) {
    return (
      <div className="attention-calm wide-card" title="@你、分配给你、评论，到期的问题和请你审核的合并请求会出现在这里">
        <CheckCircle2 size={15} />
        没有需要处理的事
        <button className="btn subtle icon" title="刷新" onClick={refresh} disabled={loading}>
          <RefreshCw size={13} className={loading ? "spin" : ""} />
        </button>
      </div>
    );
  }

  return (
    <div className="card home-card wide-card attention">
      <div className="card-title">
        <h2>
          需要处理 {items.length > 0 && <span className="count">{items.length}</span>}
        </h2>
        <button className="btn subtle icon" title="刷新" onClick={refresh} disabled={loading}>
          <RefreshCw size={14} className={loading ? "spin" : ""} />
        </button>
      </div>
      {error && <p className="notice error small">{error}</p>}
      {view?.notes.map((n) => (
        <p key={n} className="notice warn small">
          {n}
        </p>
      ))}
      {!view && !error && <Skeleton lines={3} />}
      {items.length > 0 && (
        <ul className="inbox-list">
          {items.map((item) => (
            <AttentionRow
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
        </ul>
      )}

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
      {contextMenu.menu}
    </div>
  );
}

function ItemIcon({ item }: { item: InboxItem }) {
  const Icon = item.source === "due" ? Clock3 : item.source === "mr" ? GitPullRequest : item.system === "wiki" ? BookText : CircleDot;
  return (
    <span className={`inbox-icon source-${item.source}`}>
      <Icon size={14} />
    </span>
  );
}

function AttentionRow(props: {
  item: InboxItem;
  menuOpen: boolean;
  onOpen: () => void;
  onToday: () => void;
  onDone: () => void;
  onSnooze: (e: React.MouseEvent) => void;
  onMenu: (e: React.MouseEvent) => void;
}) {
  const { item } = props;
  const detail = itemDetail(item);
  return (
    <li className={`inbox-row${props.menuOpen ? " menu-target" : ""}`} onContextMenu={props.onMenu}>
      <ItemIcon item={item} />
      <div className="inbox-text">
        <button className="link-plain ellipsis inbox-title" onClick={props.onOpen}>
          {item.title || "无标题"}
        </button>
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
        <button className="btn subtle icon" title="已处理" onClick={props.onDone}>
          <Check size={15} />
        </button>
        <button className="btn subtle icon" title="更多" onClick={props.onMenu}>
          <ChevronDown size={14} />
        </button>
      </span>
    </li>
  );
}
