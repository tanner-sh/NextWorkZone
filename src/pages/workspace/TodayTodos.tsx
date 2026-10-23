import { useCallback, useEffect, useState } from "react";
import { BookText, ArrowRight, CalendarDays, Check, CheckSquare, CircleDot } from "lucide-react";
import { api, type Todo } from "../../api";
import { formatDay, today, useWorkspaceRefresh, workspaceChanged } from "../../lib/workspace";
import { useNav } from "../../state/nav";
import { useContextMenu } from "../../components/ContextMenu";
import { todoMenu } from "./todoMenu";

/** 首页的“今天”：到期（含逾期）的待办，可直接勾选；添加和安排在“待办”页（或 ⌘⇧N）。 */
export function TodayTodos() {
  const { navigate } = useNav();
  const [todos, setTodos] = useState<Todo[] | null>(null);
  const contextMenu = useContextMenu();
  const day = today();

  const load = useCallback(() => {
    api.wsTodos().then((list) => setTodos(list.filter((t) => !t.done && t.due !== null && t.due <= day)), () => setTodos([]));
  }, [day]);
  useEffect(load, [load]);
  useWorkspaceRefresh(load);

  const complete = async (todo: Todo) => {
    setTodos((list) => list?.filter((t) => t.id !== todo.id) ?? list);
    await api.wsSetTodoDone(todo.id, true);
    workspaceChanged();
  };

  const sorted = [...(todos ?? [])].sort((a, b) => (a.due ?? "").localeCompare(b.due ?? "") || b.priority - a.priority);

  return (
    <div className="card home-card">
      <div className="card-title">
        <h2>
          <CheckSquare size={16} className="muted" />
          今天的待办 {todos && todos.length > 0 && <span className="count">{todos.length}</span>}
        </h2>
        <span className="row-actions">
          <button className="btn subtle" onClick={() => navigate({ page: "notes", docId: `daily-${day}` })}>
            <CalendarDays size={14} />
            写日记
          </button>
          <button className="btn subtle" onClick={() => navigate({ page: "todos" })}>
            全部 <ArrowRight size={14} />
          </button>
        </span>
      </div>
      <ul className="home-list">
        {sorted.map((t) => (
          <li key={t.id}>
            <div
              className={`home-row${contextMenu.target === t.id ? " menu-target" : ""}`}
              // 列表随 workspaceChanged 刷新，不需要单独更新
              onContextMenu={(e) => contextMenu.open(e, todoMenu(t, { onSaved: () => {}, onDeleted: () => {}, navigate }), t.id)}
            >
              <button className={`check prio-${t.priority}`} onClick={() => complete(t)} aria-label="完成">
                <Check size={11} strokeWidth={3} className="check-hover" />
              </button>
              <button className="link-plain ellipsis grow" onClick={() => navigate({ page: "todos", todoId: t.id })}>
                {t.title}
              </button>
              {t.refKey && t.refSystem === "jira" && (
                <span className="ref-chip">
                  <CircleDot size={11} />
                  {t.refKey}
                </span>
              )}
              {t.refKey && t.refSystem === "wiki" && (
                <span className="ref-chip" title={t.refTitle ?? ""}>
                  <BookText size={11} />
                  Wiki
                </span>
              )}
              {t.due && t.due < day && <span className="due-chip overdue">{formatDay(t.due)}</span>}
            </div>
          </li>
        ))}
        {todos && todos.length === 0 && (
          <li className="muted small" style={{ padding: "4px 0" }}>
            今天没有到期的待办。按 ⌘⇧N 随时记一条，或到
            <button className="link small" onClick={() => navigate({ page: "todos" })}>
              待办
            </button>
            中安排。
          </li>
        )}
      </ul>
      {contextMenu.menu}
    </div>
  );
}
