// 工作空间数据的通用辅助：修改后延迟同步、监听数据变化、日期处理。
import { useEffect, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import { api, WORKSPACE_SYNCED_EVENT } from "../api";

const CHANGED_EVENT = "nextworkzone-workspace-changed";
const SYNC_DELAY_MS = 4000;
let syncTimer: number | null = null;

/** 本地数据有修改：通知其他界面刷新，并在稍后同步到其他设备（连续修改只同步一次）。 */
export function workspaceChanged() {
  window.dispatchEvent(new Event(CHANGED_EVENT));
  if (syncTimer) window.clearTimeout(syncTimer);
  syncTimer = window.setTimeout(() => {
    syncTimer = null;
    api.wsSync().catch(() => {});
  }, SYNC_DELAY_MS);
}

/** 本地或其他设备的数据变化时调用 `refresh`。 */
export function useWorkspaceRefresh(refresh: () => void) {
  const ref = useRef(refresh);
  ref.current = refresh;
  useEffect(() => {
    const onChange = () => ref.current();
    window.addEventListener(CHANGED_EVENT, onChange);
    const unlisten = listen(WORKSPACE_SYNCED_EVENT, onChange);
    return () => {
      window.removeEventListener(CHANGED_EVENT, onChange);
      void unlisten.then((fn) => fn());
    };
  }, []);
}

// ---------- 日期 ----------

const pad = (n: number) => String(n).padStart(2, "0");

export function dayString(date: Date): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

export function today(): string {
  return dayString(new Date());
}

export function addDays(day: string, days: number): string {
  const [y, m, d] = day.split("-").map(Number);
  return dayString(new Date(y, m - 1, d + days));
}

/** 下一个周一。 */
export function nextMonday(): string {
  const now = new Date();
  const offset = ((8 - now.getDay()) % 7) || 7;
  return addDays(today(), offset);
}

const WEEKDAYS = "日一二三四五六";

/** 截止日期的显示：今天、明天、昨天、本周内显示星期，否则显示月日。 */
export function formatDay(day: string): string {
  const t = today();
  if (day === t) return "今天";
  if (day === addDays(t, 1)) return "明天";
  if (day === addDays(t, -1)) return "昨天";
  const [y, m, d] = day.split("-").map(Number);
  const date = new Date(y, m - 1, d);
  const diff = Math.round((date.getTime() - new Date(t).getTime()) / 86400000);
  if (diff > 1 && diff < 7) return `周${WEEKDAYS[date.getDay()]}`;
  return y === new Date().getFullYear() ? `${m}月${d}日` : `${y}年${m}月${d}日`;
}

export function weekdayOf(day: string): string {
  const [y, m, d] = day.split("-").map(Number);
  return `星期${WEEKDAYS[new Date(y, m - 1, d).getDay()]}`;
}

// ---------- 提醒时间 ----------

/** 毫秒时间戳 → `<input type="datetime-local">` 的值。 */
export function toLocalInput(ms: number): string {
  const d = new Date(ms);
  return `${dayString(d)}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** `<input type="datetime-local">` 的值 → 毫秒时间戳；无效时为 null。 */
export function fromLocalInput(value: string): number | null {
  if (!value) return null;
  const ms = new Date(value).getTime();
  return Number.isNaN(ms) ? null : ms;
}

/** 某天某个钟点的时间戳。 */
export function at(day: string, hour: number, minute = 0): number {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(y, m - 1, d, hour, minute).getTime();
}

/** 提醒时间的显示，例如“今天 18:00”“明天 09:00”“10月25日 09:00”。 */
export function formatMoment(ms: number): string {
  const d = new Date(ms);
  return `${formatDay(dayString(d))} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

/** 常用的提醒、稍后提醒时间：1 小时后、今天傍晚（已过时不提供）、明天上午、下周一上午。 */
export function momentPresets(): { label: string; at: number }[] {
  const now = Date.now();
  const t = today();
  const list = [{ label: "1 小时后", at: now + 3600_000 }];
  if (at(t, 18) - now > 3600_000) list.push({ label: "今天 18:00", at: at(t, 18) });
  list.push({ label: "明天 09:00", at: at(addDays(t, 1), 9) });
  list.push({ label: "下周一 09:00", at: at(nextMonday(), 9) });
  return list;
}

export const REPEAT_LABELS: Record<string, string> = { daily: "每天", weekdays: "工作日", weekly: "每周", monthly: "每月" };
