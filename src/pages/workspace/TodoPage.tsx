import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Bell, BookText, Check, CircleDot, Flag, ListChecks, Plus, Repeat as RepeatIcon, Trash2, X } from "lucide-react";
import { api, errorMessage, type ChecklistItem, type IssueChoice, type Repeat, type Todo } from "../../api";
import { ErrorBox, Skeleton } from "../../components/common";
import { useContextMenu } from "../../components/ContextMenu";
import { addDays, formatDay, formatMoment, fromLocalInput, momentPresets, nextMonday, REPEAT_LABELS, toLocalInput, today, useWorkspaceRefresh, workspaceChanged } from "../../lib/workspace";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { CreateIssueDialog } from "../jira/CreateIssueDialog";
import { Picker } from "../jira/fieldForm";
import { fromJiraSync, PRIORITIES, todoInput, todoMenu, todoTimerTarget } from "./todoMenu";
import { TimerButton } from "../../components/TimerButton";

type View = "today" | "unscheduled" | "upcoming" | "all" | "done";

const VIEWS: { id: View; label: string }[] = [
  { id: "today", label: "今天" },
  { id: "unscheduled", label: "未安排" },
  { id: "upcoming", label: "计划" },
  { id: "all", label: "全部" },
  { id: "done", label: "已完成" },
];

function inView(todo: Todo, view: View, day: string): boolean {
  if (view === "done") return todo.done;
  if (todo.done) return false;
  switch (view) {
    case "today":
      return todo.due !== null && todo.due <= day;
    case "unscheduled":
      return todo.due === null;
    case "upcoming":
      return todo.due !== null && todo.due > day;
    default:
      return true;
  }
}

/** 列表排序：完成的按完成时间倒序；未完成的按截止日期、优先级、手动顺序。 */
function compare(view: View) {
  return (a: Todo, b: Todo) => {
    if (view === "done") return (b.completedAt ?? 0) - (a.completedAt ?? 0);
    if (view === "upcoming" || view === "today") {
      const d = (a.due ?? "").localeCompare(b.due ?? "");
      if (d !== 0) return d;
    }
    return b.priority - a.priority || a.sort - b.sort || a.createdAt - b.createdAt;
  };
}

export function TodoPage() {
  const { current, navigate } = useNav();
  const { isReady } = useSettings();
  const contextMenu = useContextMenu();
  const [promoting, setPromoting] = useState<Todo | null>(null);
  const [todos, setTodos] = useState<Todo[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [view, setView] = useState<View>("today");
  const [selected, setSelected] = useState<string | null>(current.todoId ?? null);
  const [syncNote, setSyncNote] = useState<string | null>(null);
  const day = today();

  const load = useCallback(async () => {
    try {
      setTodos(await api.wsTodos());
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, []);

  useEffect(() => {
    void load();
    // 打开页面时同步一次分配给我的 Jira 问题
    api.wsRefreshJiraTodos().then(
      (r) => {
        if (r && r.added + r.completed + r.reopened > 0) {
          setSyncNote([r.added && `新增 ${r.added} 个`, r.completed && `完成 ${r.completed} 个`, r.reopened && `恢复 ${r.reopened} 个`].filter(Boolean).join("、") + "来自 Jira 的待办");
          workspaceChanged();
        }
      },
      () => {},
    );
  }, [load]);
  useWorkspaceRefresh(load);

  useEffect(() => {
    if (current.page === "todos" && current.todoId) setSelected(current.todoId);
  }, [current]);

  const counts = useMemo(() => {
    const result = {} as Record<View, number>;
    for (const v of VIEWS) result[v.id] = (todos ?? []).filter((t) => inView(t, v.id, day)).length;
    return result;
  }, [todos, day]);

  const visible = useMemo(() => (todos ?? []).filter((t) => inView(t, view, day)).sort(compare(view)), [todos, view, day]);
  const selectedTodo = todos?.find((t) => t.id === selected) ?? null;

  const replace = (todo: Todo) => {
    setTodos((list) => (list?.some((t) => t.id === todo.id) ? list.map((t) => (t.id === todo.id ? todo : t)) : [todo, ...(list ?? [])]));
    workspaceChanged();
  };

  const removeLocal = (todo: Todo) => {
    setTodos((list) => list?.filter((t) => t.id !== todo.id) ?? list);
    setSelected((id) => (id === todo.id ? null : id));
  };

  const toggle = async (todo: Todo) => {
    try {
      replace(await api.wsSetTodoDone(todo.id, !todo.done));
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  return (
    <div className="split todo-page">
      <aside className="list-pane todo-list-pane">
        <div className="list-toolbar">
          <div className="segmented todo-views">
            {VIEWS.map((v) => (
              <button key={v.id} className={view === v.id ? "active" : ""} onClick={() => setView(v.id)}>
                {v.label}
                {v.id !== "done" && counts[v.id] > 0 && <span className="seg-count">{counts[v.id]}</span>}
              </button>
            ))}
          </div>
          <QuickAdd
            view={view}
            onAdded={(todo) => {
              replace(todo);
              setSelected(todo.id);
            }}
          />
          {syncNote && (
            <div className="notice ok small">
              <span className="grow">{syncNote}</span>
              <button className="btn subtle icon" onClick={() => setSyncNote(null)} aria-label="关闭">
                <X size={13} />
              </button>
            </div>
          )}
        </div>
        {error && <ErrorBox message={error} onRetry={load} />}
        {!todos && !error && (
          <div style={{ padding: "8px 12px" }}>
            <Skeleton lines={6} height={18} />
          </div>
        )}
        <ul className="todo-list">
          {visible.map((todo) => (
            <TodoRow
              key={todo.id}
              todo={todo}
              day={day}
              selected={todo.id === selected}
              menuOpen={contextMenu.target === todo.id}
              onSelect={() => setSelected(todo.id)}
              onToggle={() => toggle(todo)}
              onContextMenu={(e) =>
                contextMenu.open(
                  e,
                  todoMenu(todo, {
                    onSaved: replace,
                    onDeleted: removeLocal,
                    navigate,
                    onPromote: isReady("jira") ? setPromoting : undefined,
                  }),
                  todo.id,
                )
              }
            />
          ))}
          {todos && visible.length === 0 && (
            <li className="muted list-empty">
              {EMPTY[view]}
              {view === "today" && counts.unscheduled > 0 && (
                <div>
                  <button className="link small" onClick={() => setView("unscheduled")}>
                    从 {counts.unscheduled} 个未安排的待办中挑几个
                  </button>
                </div>
              )}
            </li>
          )}
        </ul>
      </aside>
      <section className="detail-pane">
        {selectedTodo ? (
          <TodoDetail
            key={selectedTodo.id}
            todo={selectedTodo}
            onSaved={replace}
            onDeleted={() => {
              removeLocal(selectedTodo);
              workspaceChanged();
            }}
          />
        ) : (
          <div className="empty-center">
            <div className="muted">选择左侧的待办查看详情</div>
            <div className="muted small">随时按 ⌘⇧N 快速记一条待办</div>
          </div>
        )}
      </section>
      {contextMenu.menu}
      {promoting && (
        <CreateIssueDialog
          initial={{ summary: promoting.title, description: promoting.notes }}
          onClose={() => setPromoting(null)}
          onCreated={async (key) => {
            const todo = promoting;
            setPromoting(null);
            try {
              replace(await api.wsSaveTodo(todoInput(todo, { refSystem: "jira", refKey: key, refTitle: todo.title })));
            } catch (e) {
              setError(errorMessage(e));
            }
          }}
        />
      )}
    </div>
  );
}

const EMPTY: Record<View, string> = {
  today: "今天没有到期的待办",
  unscheduled: "没有未安排日期的待办",
  upcoming: "没有计划中的待办",
  all: "没有未完成的待办",
  done: "还没有完成的待办",
};

function QuickAdd({ view, onAdded }: { view: View; onAdded: (todo: Todo) => void }) {
  const [title, setTitle] = useState("");
  const [error, setError] = useState<string | null>(null);
  const add = async () => {
    const text = title.trim();
    if (!text) return;
    // 在“今天”“计划”视图中添加的待办分别默认今天、明天到期
    const due = view === "today" ? today() : view === "upcoming" ? addDays(today(), 1) : null;
    try {
      onAdded(await api.wsSaveTodo({ title: text, due }));
      setTitle("");
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  };
  return (
    <>
      <div className="input-icon quick-add">
        <Plus size={15} />
        <input
          value={title}
          placeholder={view === "today" ? "添加今天的待办，回车保存" : "添加待办，回车保存"}
          onChange={(e) => setTitle(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.nativeEvent.isComposing) {
              e.preventDefault();
              void add();
            }
          }}
        />
      </div>
      {error && <ErrorBox message={error} />}
    </>
  );
}

function TodoRow(props: { todo: Todo; day: string; selected: boolean; menuOpen: boolean; onSelect: () => void; onToggle: () => void; onContextMenu: (e: React.MouseEvent) => void }) {
  const { todo, day, selected, menuOpen, onSelect, onToggle } = props;
  const overdue = !todo.done && todo.due !== null && todo.due < day;
  return (
    <li className={`todo-row${selected ? " selected" : ""}${menuOpen ? " menu-target" : ""}${todo.done ? " done" : ""}`} onClick={onSelect} onContextMenu={props.onContextMenu}>
      <button
        className={`check prio-${todo.priority}${todo.done ? " checked" : ""}`}
        onClick={(e) => {
          e.stopPropagation();
          onToggle();
        }}
        aria-label={todo.done ? "标记为未完成" : "标记为完成"}
      >
        {todo.done && <Check size={12} strokeWidth={3} />}
      </button>
      <div className="todo-main">
        <div className="todo-title">{todo.title || <span className="muted">无标题</span>}</div>
        {(todo.due || todo.refKey || todo.notes || todo.priority > 0 || todo.remindAt || todo.repeat || todo.checklist.length > 0) && (
          <div className="todo-meta">
            {todo.due && <span className={`due-chip${overdue ? " overdue" : todo.due === day ? " today" : ""}`}>{formatDay(todo.due)}</span>}
            {todo.remindAt && !todo.done && (
              <span className={`meta-chip${todo.remindAt < Date.now() ? " overdue" : ""}`} title="提醒时间">
                <Bell size={11} />
                {formatMoment(todo.remindAt)}
              </span>
            )}
            {todo.repeat && (
              <span className="meta-chip" title="重复">
                <RepeatIcon size={11} />
                {REPEAT_LABELS[todo.repeat]}
              </span>
            )}
            {todo.checklist.length > 0 && (
              <span className="meta-chip" title="检查项">
                <ListChecks size={11} />
                {todo.checklist.filter((c) => c.done).length}/{todo.checklist.length}
              </span>
            )}
            {todo.priority > 0 && (
              <span className={`prio-flag prio-${todo.priority}`}>
                <Flag size={11} />
                {PRIORITIES[todo.priority]}
              </span>
            )}
            {todo.refKey && todo.refSystem === "wiki" ? (
              <span className="ref-chip" title={todo.refTitle ?? ""}>
                <BookText size={11} />
                <span className="ellipsis">{todo.refTitle ?? "Wiki 页面"}</span>
              </span>
            ) : (
              todo.refKey && (
                <span className="ref-chip">
                  <CircleDot size={11} />
                  {todo.refKey}
                </span>
              )
            )}
            {todo.notes && <span className="muted ellipsis">{todo.notes.split("\n")[0]}</span>}
          </div>
        )}
      </div>
    </li>
  );
}

function TodoDetail({ todo, onSaved, onDeleted }: { todo: Todo; onSaved: (todo: Todo) => void; onDeleted: () => void }) {
  const { navigate } = useNav();
  const { isReady } = useSettings();
  const [draft, setDraft] = useState(todo);
  const [error, setError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [promoting, setPromoting] = useState(false);
  const timer = useRef<number | null>(null);
  const latest = useRef(draft);
  latest.current = draft;

  // 外部更新（例如同步、勾选完成）时刷新未在编辑的字段
  useEffect(() => {
    setDraft((d) => ({ ...todo, title: timer.current ? d.title : todo.title, notes: timer.current ? d.notes : todo.notes }));
  }, [todo]);

  const save = useCallback(
    async (next: Todo) => {
      try {
        onSaved(await api.wsSaveTodo(todoInput(next)));
        setError(null);
      } catch (e) {
        setError(errorMessage(e));
      }
    },
    [onSaved],
  );

  /** 文字输入停顿后保存，其他修改立即保存。 */
  const update = (patch: Partial<Todo>, debounce = false) => {
    const next = { ...latest.current, ...patch };
    setDraft(next);
    if (timer.current) window.clearTimeout(timer.current);
    if (debounce) {
      timer.current = window.setTimeout(() => {
        timer.current = null;
        void save(latest.current);
      }, 500);
    } else {
      timer.current = null;
      void save(next);
    }
  };

  // 切换到其他待办前保存未提交的输入
  useEffect(
    () => () => {
      if (timer.current) {
        window.clearTimeout(timer.current);
        void save(latest.current);
      }
    },
    [save],
  );

  const remove = async () => {
    try {
      await api.wsDeleteTodo(todo.id);
      onDeleted();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  const linked: IssueChoice | null = draft.refSystem === "jira" && draft.refKey ? { key: draft.refKey, summary: draft.refTitle ?? "" } : null;

  return (
    <div className="detail-body todo-detail">
      <div className="todo-detail-head">
        <button className={`check large prio-${draft.priority}${draft.done ? " checked" : ""}`} onClick={() => update({ done: !draft.done })} aria-label="切换完成状态">
          {draft.done && <Check size={14} strokeWidth={3} />}
        </button>
        <input className="todo-title-input" value={draft.title} placeholder="待办标题" onChange={(e) => update({ title: e.target.value }, true)} />
      </div>
      {draft.autoDone && draft.done && <p className="muted small">关联的 Jira 问题已解决或不再分配给你，已自动完成。</p>}

      <div className="todo-props">
        <div className="prop-row">
          <span className="field-name">截止日期</span>
          <div className="prop-value">
            <input type="date" value={draft.due ?? ""} onChange={(e) => update({ due: e.target.value || null })} />
            <button className="btn small-btn" onClick={() => update({ due: today() })}>
              今天
            </button>
            <button className="btn small-btn" onClick={() => update({ due: addDays(today(), 1) })}>
              明天
            </button>
            <button className="btn small-btn" onClick={() => update({ due: nextMonday() })}>
              下周一
            </button>
            {draft.due && (
              <button className="btn subtle small-btn" onClick={() => update({ due: null })}>
                清除
              </button>
            )}
          </div>
        </div>
        <div className="prop-row">
          <span className="field-name">优先级</span>
          <div className="segmented">
            {PRIORITIES.map((label, p) => (
              <button key={p} className={draft.priority === p ? "active" : ""} onClick={() => update({ priority: p })}>
                {p > 0 && <Flag size={12} className={`prio-flag prio-${p}`} />}
                {label}
              </button>
            ))}
          </div>
        </div>
        <div className="prop-row">
          <span className="field-name">提醒</span>
          <div className="prop-value">
            <input type="datetime-local" value={draft.remindAt ? toLocalInput(draft.remindAt) : ""} onChange={(e) => update({ remindAt: fromLocalInput(e.target.value) })} />
            {momentPresets().map((p) => (
              <button key={p.label} className="btn small-btn" onClick={() => update({ remindAt: p.at })}>
                {p.label}
              </button>
            ))}
            {draft.remindAt && (
              <button className="btn subtle small-btn" onClick={() => update({ remindAt: null })}>
                清除
              </button>
            )}
          </div>
        </div>
        <div className="prop-row">
          <span className="field-name">重复</span>
          <div className="segmented">
            {([null, "daily", "weekdays", "weekly", "monthly"] as (Repeat | null)[]).map((r) => (
              <button
                key={r ?? "none"}
                className={draft.repeat === r ? "active" : ""}
                // 重复的待办需要一个起始日期，没有截止日期时从今天开始
                onClick={() => update({ repeat: r, due: r && !draft.due ? today() : draft.due })}
              >
                {r ? REPEAT_LABELS[r] : "不重复"}
              </button>
            ))}
          </div>
        </div>
        {draft.repeat && <p className="muted small">完成后自动生成下一次{draft.remindAt ? "，提醒时间随之顺延" : ""}。</p>}
        {draft.refSystem === "wiki" && draft.refKey && (
          <div className="prop-row">
            <span className="field-name">Wiki 页面</span>
            <div className="prop-value grow">
              <span className="linked-issue">
                <BookText size={14} className="muted" />
                <button className="link ellipsis" onClick={() => navigate({ page: "wiki", wikiPage: draft.refKey! })}>
                  {draft.refTitle ?? draft.refKey}
                </button>
                {todo.source === "wiki" && <span className="muted small nowrap">页面任务，勾选后同步到 Wiki</span>}
              </span>
            </div>
          </div>
        )}
        <div className="prop-row" hidden={draft.refSystem === "wiki"}>
          <span className="field-name">关联问题</span>
          <div className="prop-value grow">
            {linked ? (
              <span className="linked-issue">
                <button className="link" onClick={() => navigate({ page: "jira", issueKey: linked.key })}>
                  {linked.key}
                </button>
                <span className="ellipsis">{linked.summary}</span>
                <button className="btn subtle icon" title="取消关联" onClick={() => update({ refSystem: null, refKey: null, refTitle: null })}>
                  <X size={14} />
                </button>
              </span>
            ) : isReady("jira") ? (
              <div className="grow">
                <Picker<IssueChoice>
                  selected={[]}
                  onChange={(list) => list[0] && update({ refSystem: "jira", refKey: list[0].key, refTitle: list[0].summary })}
                  search={async (q) => (q.trim() ? (await api.jiraPickIssues(q, null, false)).map((i) => ({ key: i.key, summary: i.summary })) : [])}
                  label={(c) => c.key}
                  detail={(c) => c.summary}
                  id={(c) => c.key}
                  placeholder="输入问题键或概要搜索 Jira 问题"
                />
              </div>
            ) : (
              <span className="muted small">配置 Jira 后可关联问题</span>
            )}
          </div>
        </div>
      </div>

      <Checklist items={draft.checklist} onChange={(checklist, debounce) => update({ checklist }, debounce)} />

      <div className="form-field">
        <span>备注</span>
        <textarea className="todo-notes" rows={8} value={draft.notes} placeholder="补充说明、链接、检查项…" onChange={(e) => update({ notes: e.target.value }, true)} />
      </div>

      {error && <ErrorBox message={error} />}

      <div className="todo-actions">
        <TimerButton target={todoTimerTarget(draft)} match={{ todoId: todo.id }} />
        {!linked && isReady("jira") && (
          <button className="btn" onClick={() => setPromoting(true)}>
            <CircleDot size={14} />
            创建为 Jira 问题
          </button>
        )}
        <span className="spacer" />
        {!confirmDelete && <span className="muted small">创建于 {new Date(todo.createdAt).toLocaleString()}</span>}
        {confirmDelete ? (
          <span className="inline-confirm">
            {linked && <span className="muted small">{fromJiraSync(todo) ? "只删除待办，不影响 Jira 问题，之后也不会再自动添加" : "只删除待办，不影响 Jira 问题"}</span>}
            <button className="btn danger small-btn" onClick={remove}>
              确认删除
            </button>
            <button className="btn small-btn" onClick={() => setConfirmDelete(false)}>
              取消
            </button>
          </span>
        ) : (
          <button className="btn subtle" onClick={() => setConfirmDelete(true)}>
            <Trash2 size={14} />
            {linked ? "删除待办" : "删除"}
          </button>
        )}
      </div>

      {promoting && (
        <CreateIssueDialog
          initial={{ summary: draft.title, description: draft.notes }}
          onClose={() => setPromoting(false)}
          onCreated={(key) => {
            setPromoting(false);
            update({ refSystem: "jira", refKey: key, refTitle: draft.title });
          }}
        />
      )}
    </div>
  );
}

/** 检查项（子任务）：勾选、改文字、删除，底部输入框回车添加。 */
function Checklist({ items, onChange }: { items: ChecklistItem[]; onChange: (items: ChecklistItem[], debounce?: boolean) => void }) {
  const [draft, setDraft] = useState("");
  const add = () => {
    const text = draft.trim();
    if (!text) return;
    onChange([...items, { id: crypto.randomUUID(), text, done: false }]);
    setDraft("");
  };
  const done = items.filter((i) => i.done).length;
  return (
    <div className="form-field checklist">
      <span>
        检查项{items.length > 0 && <span className="muted small"> {done}/{items.length}</span>}
      </span>
      {items.length > 0 && (
        <ul>
          {items.map((item) => (
            <li key={item.id} className={item.done ? "done" : ""}>
              <button
                className={`check small${item.done ? " checked" : ""}`}
                onClick={() => onChange(items.map((i) => (i.id === item.id ? { ...i, done: !i.done } : i)))}
                aria-label={item.done ? "标记为未完成" : "标记为完成"}
              >
                {item.done && <Check size={10} strokeWidth={3} />}
              </button>
              <input value={item.text} onChange={(e) => onChange(items.map((i) => (i.id === item.id ? { ...i, text: e.target.value } : i)), true)} />
              <button className="btn subtle icon" title="删除" onClick={() => onChange(items.filter((i) => i.id !== item.id))}>
                <X size={13} />
              </button>
            </li>
          ))}
        </ul>
      )}
      <div className="input-icon quick-add">
        <Plus size={14} />
        <input
          value={draft}
          placeholder="添加检查项，回车保存"
          onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && !e.nativeEvent.isComposing) {
              e.preventDefault();
              add();
            }
          }}
        />
      </div>
    </div>
  );
}
