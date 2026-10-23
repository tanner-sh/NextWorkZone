/** Jira 时长（3d 4h 30m）显示为中文单位，与 Jira 网页一致（3日 4小时 30分钟）。 */
export function localizeDuration(value: string): string {
  const units: Record<string, string> = { w: "周", d: "日", h: "小时", m: "分钟" };
  return value.replace(/(\d+(?:\.\d+)?)([wdhm])\b/g, (_, n: string, u: string) => `${n}${units[u]}`);
}

/** 解析三个系统返回的时间。Jira 使用 `+0800` 形式的时区，需要先补上冒号。 */
export function parseTime(value: string): Date {
  return new Date(value.replace(/([+-]\d{2})(\d{2})$/, "$1:$2"));
}

const pad = (n: number) => String(n).padStart(2, "0");

/** 一小时内显示“x 分钟前”，当天显示时间，今年显示月日，否则显示完整日期。 */
export function formatTime(value: string | null | undefined): string {
  if (!value) return "";
  const date = parseTime(value);
  if (Number.isNaN(date.getTime())) return value;
  const now = new Date();
  const minutes = Math.floor((now.getTime() - date.getTime()) / 60000);
  if (minutes >= 0 && minutes < 60) return minutes <= 1 ? "刚刚" : `${minutes} 分钟前`;
  const hm = `${pad(date.getHours())}:${pad(date.getMinutes())}`;
  if (date.toDateString() === now.toDateString()) return `今天 ${hm}`;
  const md = `${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
  if (date.getFullYear() === now.getFullYear()) return `${md} ${hm}`;
  return `${date.getFullYear()}-${md}`;
}

export function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}
