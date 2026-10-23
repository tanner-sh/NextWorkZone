// 需要处理的事（内部沿用“收件箱”的名字）：各界面共享最近一次汇总的结果（侧边栏数量、今天页），以及条目的常用操作。
import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { api, INBOX_EVENT, type InboxItem, type InboxView, type Todo } from "../api";
import { action, activityTarget, detail } from "./activity";
import { reminderLabel } from "./reminders";
import type { NavTarget } from "../state/nav";
import { todoInput } from "../pages/workspace/todoMenu";
import { workspaceChanged } from "./workspace";

const INBOX_CHANGED = "nextworkzone-inbox";
let latest: InboxView | null = null;
let pending: Promise<InboxView> | null = null;

function publish(view: InboxView) {
  latest = view;
  window.dispatchEvent(new CustomEvent(INBOX_CHANGED, { detail: view }));
}

/** 重新汇总；同时发起的多次刷新合并为一次。 */
export function refreshInbox(): Promise<InboxView> {
  pending ??= api.wsInbox().then(
    (view) => {
      pending = null;
      publish(view);
      return view;
    },
    (e) => {
      pending = null;
      throw e;
    },
  );
  return pending;
}

/** 最近一次汇总的结果；后端通知有变化（稍后提醒到时）时自动刷新。 */
export function useInbox(): InboxView | null {
  const [view, setView] = useState<InboxView | null>(latest);
  useEffect(() => {
    const onChange = (e: Event) => setView((e as CustomEvent<InboxView>).detail);
    window.addEventListener(INBOX_CHANGED, onChange);
    const unlisten = listen(INBOX_EVENT, () => void refreshInbox().catch(() => {}));
    return () => {
      window.removeEventListener(INBOX_CHANGED, onChange);
      void unlisten.then((fn) => fn());
    };
  }, []);
  return view;
}

/** 先从本地列表中去掉条目（界面立即响应），再记下处理状态。 */
export async function handleItem(item: InboxItem) {
  if (latest) publish({ ...latest, items: latest.items.filter((i) => i.id !== item.id), snoozed: latest.snoozed.filter((i) => i.id !== item.id) });
  await api.wsInboxHandle({ id: item.id, title: item.title, eventIds: item.events.map((e) => e.id) });
  void refreshInbox().catch(() => {});
}

export async function snoozeItem(item: InboxItem, until: number | null) {
  await api.wsInboxSnooze(item.id, item.title, until);
  await refreshInbox();
}

/** 条目的第二行说明。 */
export function itemDetail(item: InboxItem): string {
  switch (item.source) {
    case "activity": {
      const e = item.events[0];
      if (!e) return "";
      const text = `${e.actor} ${action(e)}${detail(e) ? `：${detail(e)}` : ""}`;
      return item.events.length > 1 ? `${text}（共 ${item.events.length} 条）` : text;
    }
    case "due":
      return [item.dueKind ? reminderLabel(item.dueKind, item.dueDays ?? 0) : "", item.detail].filter(Boolean).join(" · ");
    case "mr":
      return item.detail;
  }
}

/** 打开条目对应的问题、页面或合并请求。 */
export function itemTarget(item: InboxItem): NavTarget | null {
  switch (item.source) {
    case "activity":
      return item.events[0] ? activityTarget(item.events[0]) : null;
    case "due":
      return item.key ? { page: "jira", issueKey: item.key } : null;
    case "mr":
      return item.mr ? { page: "gitlab", projectId: item.mr.projectId, mrIid: item.mr.iid } : null;
  }
}

/**
 * 转为待办（截止日期 `due`）。关联的 Jira 问题已有未完成的待办（例如自动加入的）时改它的日期，不重复创建。
 * 转换后条目记为已处理。
 */
export async function itemToTodo(item: InboxItem, due: string | null, todos: Todo[]): Promise<Todo> {
  const jiraKey = item.system === "jira" ? item.key : null;
  const existing = jiraKey ? todos.find((t) => !t.done && t.refSystem === "jira" && t.refKey === jiraKey) : undefined;
  let todo: Todo;
  if (existing) {
    todo = await api.wsSaveTodo(todoInput(existing, { due }));
  } else {
    const summary = item.events[0]?.issueSummary ?? item.title.replace(/^[A-Z][A-Z0-9_]+-\d+\s+/, "");
    const input =
      item.system === "jira" && item.key
        ? { title: summary, refSystem: "jira", refKey: item.key, refTitle: summary }
        : item.system === "wiki" && item.key
          ? { title: item.title, refSystem: "wiki", refKey: item.key, refTitle: item.title }
          : { title: `审核 ${item.mr?.reference ?? ""} ${item.title}`.trim(), notes: item.url ?? "" };
    todo = await api.wsSaveTodo({ ...input, due });
  }
  await handleItem(item);
  workspaceChanged();
  return todo;
}
