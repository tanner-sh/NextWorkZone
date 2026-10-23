// 把草稿条目并入正在编辑的周报：放到同名分组下面，已有的同一条只更新进度，不重复插入。
import { withIds, type EditorItem } from "./OutlineEditor";

/** 条目末尾的进度：--100%、------90%、– 100%、--转开发解决（与后端的规则一致）。 */
const PROGRESS = /^(.*?\S)\s*(?:-{2,}|–|—)\s*([^\s\-–—][^\-–—]{0,11})\s*$/;

/** 不含进度的内容，去掉空白和标点，用于判断是否同一条。 */
export function baseText(text: string): string {
  const body = text.trim().match(PROGRESS)?.[1] ?? text.trim();
  return body.toLowerCase().replace(/[\s\p{P}\p{S}]/gu, "");
}

/** 条目在周报中的情况：没有、已有且相同、已有但进度不同。 */
export function presence(content: EditorItem[], text: string): "none" | "same" | "changed" {
  const base = baseText(text);
  const found = content.find((i) => i.text.trim() === text.trim()) ?? content.find((i) => base && baseText(i.text) === base);
  if (!found) return "none";
  return found.text.trim() === text.trim() ? "same" : "changed";
}

export interface MergeResult {
  next: EditorItem[];
  added: number;
  updated: number;
}

/**
 * 把 `texts` 并入 `content`：已有的同一条（内容相同、进度不同）改为新的文字；
 * 新条目放到第 0 层名为 `group` 的分组末尾，没有这个分组时在最后新建。`group` 为空时追加到最后。
 */
export function mergeInto(content: EditorItem[], group: string | null, texts: string[]): MergeResult {
  let next = content.filter((i) => i.text.trim() !== "");
  let updated = 0;
  const fresh: string[] = [];
  for (const text of texts) {
    const base = baseText(text);
    const index = next.findIndex((i) => i.text.trim() === text.trim() || (base !== "" && baseText(i.text) === base));
    if (index < 0) {
      if (!fresh.includes(text)) fresh.push(text);
    } else if (next[index].text.trim() !== text.trim()) {
      next = next.map((item, n) => (n === index ? { ...item, text } : item));
      updated++;
    }
  }
  if (fresh.length === 0) return { next, added: 0, updated };

  const lines = fresh.map((text) => ({ level: 1, text }));
  const head = group ? next.findIndex((i) => i.level === 0 && i.text.trim() === group.trim()) : -1;
  if (head >= 0) {
    let end = head + 1;
    while (end < next.length && next[end].level > 0) end++;
    next = [...next.slice(0, end), ...withIds(lines), ...next.slice(end)];
  } else {
    next = [...next, ...withIds(group ? [{ level: 0, text: group }, ...lines] : lines)];
  }
  return { next, added: fresh.length, updated };
}
