import type { OutlineItem } from "../../api";

export interface DiffLine {
  kind: "same" | "add" | "del";
  level: number;
  text: string;
}

const key = (i: OutlineItem) => `${i.level}\u0000${i.text.trim()}`;

/** 基于最长公共子序列的逐项对比，用于保存前展示改动。 */
export function diffOutline(before: OutlineItem[], after: OutlineItem[]): DiffLine[] {
  const a = before.map(key);
  const b = after.map(key);
  const lcs: number[][] = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      lcs[i][j] = a[i] === b[j] ? lcs[i + 1][j + 1] + 1 : Math.max(lcs[i + 1][j], lcs[i][j + 1]);
    }
  }
  const out: DiffLine[] = [];
  let i = 0;
  let j = 0;
  while (i < a.length || j < b.length) {
    if (i < a.length && j < b.length && a[i] === b[j]) {
      out.push({ kind: "same", ...before[i] });
      i++;
      j++;
    } else if (j < b.length && (i >= a.length || lcs[i][j + 1] >= lcs[i + 1][j])) {
      out.push({ kind: "add", ...after[j] });
      j++;
    } else {
      out.push({ kind: "del", ...before[i] });
      i++;
    }
  }
  return out;
}

export const sameOutline = (a: OutlineItem[], b: OutlineItem[]) =>
  a.length === b.length && a.every((item, i) => key(item) === key(b[i]));
