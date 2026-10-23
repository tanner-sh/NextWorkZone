// 计时：同一时间只计一个（问题或待办），可暂停；停止后登记为 Jira 工作日志。
// 状态保存在本机，重启应用后继续。
import { useEffect, useState } from "react";

export interface TimerTarget {
  issueKey?: string | null;
  /** 问题概要（计时目标是待办时，title 是待办标题） */
  issueSummary?: string | null;
  todoId?: string | null;
  title: string;
}

export interface TimerState {
  target: TimerTarget;
  /** 第一次开始的时间（毫秒），登记工作日志时作为开始时间 */
  firstStartedAt: number;
  /** 本段开始时间；暂停时为 null */
  runningSince: number | null;
  /** 之前各段累计的毫秒数 */
  elapsedBefore: number;
}

const KEY = "nextworkzone.timer";
const CHANGED = "nextworkzone-timer-changed";
const STOP = "nextworkzone-timer-stop";

function read(): TimerState | null {
  try {
    const raw = localStorage.getItem(KEY);
    return raw ? (JSON.parse(raw) as TimerState) : null;
  } catch {
    return null;
  }
}

function write(state: TimerState | null) {
  try {
    if (state) localStorage.setItem(KEY, JSON.stringify(state));
    else localStorage.removeItem(KEY);
  } catch {
    // 本地存储不可用时只在本次运行中有效
  }
  memory = state;
  window.dispatchEvent(new Event(CHANGED));
}

let memory: TimerState | null = read();

export function currentTimer(): TimerState | null {
  return memory;
}

export function elapsedMs(state: TimerState, now = Date.now()): number {
  return state.elapsedBefore + (state.runningSince ? now - state.runningSince : 0);
}

/** 开始计时。已有计时时先请求停止（登记后再开始新的）。 */
export function startTimer(target: TimerTarget) {
  if (memory) {
    requestStop(target);
    return;
  }
  const now = Date.now();
  write({ target, firstStartedAt: now, runningSince: now, elapsedBefore: 0 });
}

export function pauseTimer() {
  if (!memory?.runningSince) return;
  write({ ...memory, elapsedBefore: elapsedMs(memory), runningSince: null });
}

export function resumeTimer() {
  if (!memory || memory.runningSince) return;
  write({ ...memory, runningSince: Date.now() });
}

export function clearTimer() {
  write(null);
}

/** 打开“停止计时”对话框；`next` 为登记后接着开始计时的目标。 */
export function requestStop(next?: TimerTarget) {
  window.dispatchEvent(new CustomEvent(STOP, { detail: next ?? null }));
}

export function onStopRequest(handler: (next: TimerTarget | null) => void): () => void {
  const listener = (e: Event) => handler((e as CustomEvent<TimerTarget | null>).detail);
  window.addEventListener(STOP, listener);
  return () => window.removeEventListener(STOP, listener);
}

/** 当前计时，运行中时每秒刷新。 */
export function useTimer(): TimerState | null {
  const [state, setState] = useState(memory);
  const [, tick] = useState(0);
  useEffect(() => {
    const onChange = () => setState(memory);
    window.addEventListener(CHANGED, onChange);
    return () => window.removeEventListener(CHANGED, onChange);
  }, []);
  useEffect(() => {
    if (!state?.runningSince) return;
    const timer = window.setInterval(() => tick((n) => n + 1), 1000);
    return () => window.clearInterval(timer);
  }, [state?.runningSince]);
  return state;
}

/** 01:23:45 */
export function formatClock(ms: number): string {
  const total = Math.floor(ms / 1000);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${pad(Math.floor(total / 3600))}:${pad(Math.floor((total % 3600) / 60))}:${pad(total % 60)}`;
}

/** Jira 时长格式，向上取整到分钟，例如 1h 25m。 */
export function jiraDuration(ms: number): string {
  const minutes = Math.max(1, Math.ceil(ms / 60000));
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return [h && `${h}h`, m && `${m}m`].filter(Boolean).join(" ");
}

/** 是否正在为这个问题或待办计时。 */
export function isTiming(state: TimerState | null, target: { issueKey?: string | null; todoId?: string | null }): boolean {
  if (!state) return false;
  if (target.todoId) return state.target.todoId === target.todoId;
  return Boolean(target.issueKey) && state.target.issueKey === target.issueKey && !state.target.todoId;
}
