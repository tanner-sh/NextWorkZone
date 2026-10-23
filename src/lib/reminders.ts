// 我的问题的到期、停滞提醒：定期检查，每天发一次系统通知，各界面共享最新结果。
import { useEffect, useState } from "react";
import { api, type Reminder, type ReminderKind, type Reminders } from "../api";
import { notify } from "./notify";
import { today } from "./workspace";

const REMINDERS_EVENT = "nextworkzone-reminders";
const NOTIFIED_KEY = "nextworkzone.jira.remindedToday";
/** 早于这个钟点不发每天的汇总通知。 */
const NOTIFY_HOUR = 9;

let latest: Reminders | null = null;

function publish(reminders: Reminders) {
  latest = reminders;
  window.dispatchEvent(new CustomEvent(REMINDERS_EVENT, { detail: reminders }));
}

/** 最近一次检查的结果；尚未检查时为 null。 */
export function useReminders(): Reminders | null {
  const [reminders, setReminders] = useState<Reminders | null>(latest);
  useEffect(() => {
    const onChange = (e: Event) => setReminders((e as CustomEvent<Reminders>).detail);
    window.addEventListener(REMINDERS_EVENT, onChange);
    if (!latest) void checkReminders(false).catch(() => {});
    return () => window.removeEventListener(REMINDERS_EVENT, onChange);
  }, []);
  return reminders;
}

/** 检查一次；`withNotify` 为真时按设置发送系统通知（每天一次汇总，之后只通知新出现的）。 */
export async function checkReminders(withNotify = true): Promise<Reminders> {
  const reminders = await api.jiraReminders();
  publish(reminders);
  if (withNotify && reminders.remind) maybeNotify(reminders.items.filter((r) => r.kind === "overdue" || r.kind === "today"));
  return reminders;
}

function maybeNotify(due: Reminder[]) {
  if (due.length === 0) return;
  const day = today();
  let notified: { day: string; keys: string[] } = { day: "", keys: [] };
  try {
    notified = JSON.parse(localStorage.getItem(NOTIFIED_KEY) ?? "null") ?? notified;
  } catch {
    // 当作今天还没通知过
  }
  if (notified.day !== day && new Date().getHours() < NOTIFY_HOUR) return;
  const known = notified.day === day ? notified.keys : [];
  const fresh = due.filter((r) => !known.includes(r.key));
  if (fresh.length === 0) return;
  const overdue = fresh.filter((r) => r.kind === "overdue").length;
  const dueToday = fresh.length - overdue;
  const title = [overdue && `${overdue} 个问题已逾期`, dueToday && `${dueToday} 个问题今天到期`].filter(Boolean).join("，");
  void notify(title, fresh.slice(0, 3).map((r) => `${r.key} ${r.summary}`).join("\n") + (fresh.length > 3 ? `\n等 ${fresh.length} 个` : ""));
  try {
    localStorage.setItem(NOTIFIED_KEY, JSON.stringify({ day, keys: [...known, ...fresh.map((r) => r.key)] }));
  } catch {
    // 下次可能重复通知
  }
}

/** 提醒的文字，例如“逾期 2 天”“明天到期”“9 天未更新”。 */
export function reminderLabel(kind: ReminderKind, days: number): string {
  switch (kind) {
    case "overdue":
      return `逾期 ${-days} 天`;
    case "today":
      return "今天到期";
    case "soon":
      return days === 1 ? "明天到期" : `${days} 天后到期`;
    case "stale":
      return `${days} 天未更新`;
  }
}
