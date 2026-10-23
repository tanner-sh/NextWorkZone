import { useCallback, useEffect, useState } from "react";
import { AlarmClock, BellOff, BookText, CalendarDays, Check, CheckSquare, ChevronDown, ChevronRight, CircleDot, Clock3, GitPullRequest, Inbox, Plus, RefreshCw } from "lucide-react";
import { api, errorMessage, type InboxItem, type Todo } from "../../api";
import { ErrorBox, Skeleton } from "../../components/common";
import { useContextMenu, type MenuInput } from "../../components/ContextMenu";
import { guarded } from "../../components/Toast";
import { formatTime } from "../../lib/format";
import { handleItem, itemDetail, itemTarget, itemToTodo, refreshInbox, snoozeItem, useInbox } from "../../lib/inbox";
import { openLink } from "../../lib/links";
import { addDays, formatMoment, momentPresets, today, useWorkspaceRefresh } from "../../lib/workspace";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";

/**
 * 收件箱：还没处理的事（记下的内容、动态、到期问题、合并请求）。每条可以处理掉、转为待办或稍后提醒；
 * 安排哪天做在“待办”页，这里不重复显示待办。
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

  return (
    <section className="page inbox-page">
      <header className="page-header">
        <div>
          <h1>
            收件箱 {items.length > 0 && <span className="count">{items.length}</span>}
          </h1>
          <p className="muted small">需要处理的事都在这里：处理完、转为待办，或者稍后再提醒。转为待办后到“待办”页安排日期。</p>
        </div>
        <button className="btn subtle icon" title="刷新" onClick={refresh} disabled={loading}>
          <RefreshCw size={15} className={loading ? "spin" : ""} />
        </button>
      </header>

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
