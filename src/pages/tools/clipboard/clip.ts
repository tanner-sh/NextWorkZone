// 剪贴板条目的显示与识别：类型、颜色、时间，以及从内容中识别出的问题、JSON、时间戳、颜色等，用于卡片和“智能操作”。
import { useEffect, useState } from "react";
import { AlignLeft, Code2, File, Image, Link2, Palette, type LucideIcon } from "lucide-react";
import { api, type ClipItem, type ClipKind, type IssueHit, type Service } from "../../../api";
import { formatSize, formatTime } from "../../../lib/format";
import { routeUrl } from "../../../lib/links";

export const KIND_META: Record<ClipKind, { label: string; icon: LucideIcon; color: string }> = {
  text: { label: "文本", icon: AlignLeft, color: "#6b7280" },
  link: { label: "链接", icon: Link2, color: "#2563eb" },
  code: { label: "代码", icon: Code2, color: "#7c3aed" },
  color: { label: "颜色", icon: Palette, color: "#db2777" },
  image: { label: "图片", icon: Image, color: "#059669" },
  file: { label: "文件", icon: File, color: "#d97706" },
};

export const KINDS = Object.keys(KIND_META) as ClipKind[];

/** 置顶板可选的颜色。 */
export const BOARD_COLORS = ["#ef4444", "#f97316", "#eab308", "#22c55e", "#14b8a6", "#3b82f6", "#8b5cf6", "#ec4899", "#6b7280"];

export const isMac = navigator.userAgent.includes("Mac");
export const MOD = isMac ? "⌘" : "Ctrl+";

/** 卡片标题栏的颜色：来源应用图标的主色，没有时用类型的颜色。 */
export function headColor(item: ClipItem): string {
  return item.appColor ?? KIND_META[item.kind].color;
}

/** 背景色上的文字用白色还是深色。 */
export function readableOn(hex: string): string {
  const rgb = parseHex(hex);
  if (!rgb) return "#fff";
  const [r, g, b] = rgb.map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.45 ? "#18181b" : "#fff";
}

function parseHex(hex: string): [number, number, number] | null {
  const m = hex.trim().match(/^#?([0-9a-f]{3,8})$/i);
  if (!m) return null;
  let h = m[1];
  if (h.length === 3 || h.length === 4) h = h.slice(0, 3).split("").map((c) => c + c).join("");
  if (h.length !== 6 && h.length !== 8) return null;
  return [0, 2, 4].map((i) => parseInt(h.slice(i, i + 2), 16)) as [number, number, number];
}

export function timeLabel(ms: number): string {
  return formatTime(new Date(ms).toISOString());
}

export function fileName(path: string): string {
  return path.split(/[\\/]/).filter(Boolean).pop() ?? path;
}

/** 卡片底部的一行说明：字符数、尺寸、文件数等。 */
export function metaLine(item: ClipItem): string {
  switch (item.kind) {
    case "image":
      return item.image ? `${item.image.width} × ${item.image.height} · ${formatSize(item.image.bytes)}` : "图片";
    case "file":
      return item.files.length === 1 ? fileName(item.files[0]) : `${item.files.length} 个文件`;
    case "link":
      return hostOf(item.text) ?? `${item.textLength} 个字符`;
    case "color":
      return item.text.trim();
    default: {
      const lines = item.text.split("\n").length;
      return `${item.textLength.toLocaleString()} 个字符${lines > 1 ? ` · ${lines}${item.textLength > item.text.length ? "+" : ""} 行` : ""}`;
    }
  }
}

export function hostOf(url: string): string | null {
  try {
    return new URL(url.trim().startsWith("www.") ? `https://${url.trim()}` : url.trim()).host;
  } catch {
    return null;
  }
}

/** 文字中出现的问题 key（最多 3 个，去重）。 */
export function issueKeys(text: string): string[] {
  return [...new Set(text.match(/\b[A-Z][A-Z0-9_]{1,15}-\d{1,7}\b/g) ?? [])].slice(0, 3);
}

/** 内容是 JSON 时返回解析结果。 */
export function jsonOf(text: string): unknown | undefined {
  const t = text.trim();
  if (!(t.startsWith("{") && t.endsWith("}")) && !(t.startsWith("[") && t.endsWith("]"))) return undefined;
  try {
    return JSON.parse(t);
  } catch {
    return undefined;
  }
}

/** 10 位（秒）或 13 位（毫秒）的时间戳，限定在 2000–2100 年之间。 */
export function timestampOf(text: string): Date | null {
  const t = text.trim();
  if (!/^\d{10}(\d{3})?$/.test(t)) return null;
  const date = new Date(t.length === 10 ? Number(t) * 1000 : Number(t));
  const year = date.getFullYear();
  return year >= 2000 && year <= 2100 ? date : null;
}

const pad = (n: number) => String(n).padStart(2, "0");

export function formatDateTime(date: Date): string {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
}

/** 颜色的几种写法（HEX、RGB、HSL），用于“粘贴为…”。 */
export function colorFormats(text: string): { hex: string; rgb: string; hsl: string } | null {
  const t = text.trim();
  let rgb: [number, number, number] | null = parseHex(t);
  let alpha = 1;
  if (!rgb) {
    const m = t.match(/^rgba?\(\s*([\d.]+)\s*[, ]\s*([\d.]+)\s*[, ]\s*([\d.]+)\s*(?:[,/]\s*([\d.]+%?)\s*)?\)$/i);
    if (m) {
      rgb = [Number(m[1]), Number(m[2]), Number(m[3])];
      if (m[4]) alpha = m[4].endsWith("%") ? Number(m[4].slice(0, -1)) / 100 : Number(m[4]);
    }
  }
  if (!rgb) return null;
  const [r, g, b] = rgb.map((v) => Math.max(0, Math.min(255, Math.round(v))));
  const hex = `#${[r, g, b].map((v) => v.toString(16).padStart(2, "0")).join("")}`;
  const [h, s, l] = toHsl(r, g, b);
  const a = alpha < 1 ? ` / ${Math.round(alpha * 100) / 100}` : "";
  return { hex, rgb: alpha < 1 ? `rgba(${r}, ${g}, ${b}, ${alpha})` : `rgb(${r}, ${g}, ${b})`, hsl: `hsl(${h} ${s}% ${l}%${a})` };
}

function toHsl(r: number, g: number, b: number): [number, number, number] {
  const [rn, gn, bn] = [r / 255, g / 255, b / 255];
  const max = Math.max(rn, gn, bn);
  const min = Math.min(rn, gn, bn);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, Math.round(l * 100)];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  const h = max === rn ? (gn - bn) / d + (gn < bn ? 6 : 0) : max === gn ? (bn - rn) / d + 2 : (rn - gn) / d + 4;
  return [Math.round(h * 60), Math.round(s * 100), Math.round(l * 100)];
}

/** 链接指向的应用内页面的说明，例如“Jira 问题 PROJ-1”；不是已配置系统的地址时返回 null。 */
export function inAppLabel(url: string, baseUrl: (service: Service) => string): string | null {
  const route = routeUrl(url, baseUrl);
  if (!route) return null;
  if (route === "wiki" || route.page === "wiki") return "Wiki 页面";
  if (route.page === "jira") return `Jira 问题 ${route.issueKey}`;
  if (route.mrIid) return `合并请求 !${route.mrIid}`;
  return `代码项目 ${route.projectPath ?? ""}`;
}

/** 链接中的 Jira 问题 key。 */
export function linkIssueKey(url: string, baseUrl: (service: Service) => string): string | null {
  const route = routeUrl(url, baseUrl);
  return route && route !== "wiki" && route.page === "jira" ? (route.issueKey ?? null) : null;
}

// ---------- 问题信息（来自本机问题库） ----------

const issueCache = new Map<string, IssueHit | null>();
const pending = new Set<string>();
const ISSUE_EVENT = "nextworkzone-clip-issues";
let batchTimer: number | undefined;

function requestIssues(keys: string[]) {
  for (const key of keys) if (!issueCache.has(key)) pending.add(key);
  if (pending.size === 0 || batchTimer !== undefined) return;
  // 同一轮渲染中的请求合并为一次
  batchTimer = window.setTimeout(() => {
    batchTimer = undefined;
    const batch = [...pending];
    pending.clear();
    api.clipIssues(batch).then(
      (hits) => {
        for (const key of batch) issueCache.set(key, hits.find((h) => h.key === key) ?? null);
        window.dispatchEvent(new Event(ISSUE_EVENT));
      },
      () => batch.forEach((key) => issueCache.set(key, null)),
    );
  }, 30);
}

/** 本机问题库中的问题（没有同步问题库或库中没有时为 null）。 */
export function useIssues(keys: string[], enabled: boolean): IssueHit[] {
  const signature = keys.join(",");
  const [, setVersion] = useState(0);
  useEffect(() => {
    if (!enabled || !signature) return;
    const update = () => setVersion((v) => v + 1);
    window.addEventListener(ISSUE_EVENT, update);
    requestIssues(signature.split(","));
    return () => window.removeEventListener(ISSUE_EVENT, update);
  }, [signature, enabled]);
  if (!enabled) return [];
  return keys.map((k) => issueCache.get(k)).filter((h): h is IssueHit => Boolean(h));
}
