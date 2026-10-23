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
