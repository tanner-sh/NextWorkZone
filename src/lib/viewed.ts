// 问题的查看记录：列表中标出上次查看之后有新变化的问题，详情中显示具体变化。
import { useEffect, useMemo, useState } from "react";
import { api, type IssueSummary } from "../api";
import { parseTime } from "./format";

const VIEWED_EVENT = "nextworkzone-issue-viewed";

function ms(value: string | null | undefined): number {
  if (!value) return 0;
  const t = parseTime(value).getTime();
  return Number.isNaN(t) ? 0 : t;
}

/** 上次查看的时间：本应用中的记录与 Jira 网页上的“最近查看”取较晚的；都没有时为 null。 */
export function lastSeen(local: number | null | undefined, issue: Pick<IssueSummary, "lastViewed">): number | null {
  return Math.max(local ?? 0, ms(issue.lastViewed)) || null;
}

/** 记录查看了问题（在详情中打开、自己修改后），返回之前的查看时间。 */
export async function markViewed(issue: Pick<IssueSummary, "key" | "updated">): Promise<number | null> {
  const previous = await api.jiraMarkViewed(issue.key, issue.updated);
  window.dispatchEvent(new CustomEvent(VIEWED_EVENT, { detail: { key: issue.key, at: Math.max(Date.now(), ms(issue.updated)) } }));
  return previous;
}

/** 列表中的问题是否有尚未查看的变化。从未查看过的问题，以开始记录之后的更新为准。 */
export function useUnseen(issues: IssueSummary[] | null): (issue: IssueSummary) => boolean {
  const [state, setState] = useState<{ viewed: Record<string, number>; baseline: number } | null>(null);
  const keys = useMemo(() => (issues ?? []).map((i) => i.key).join(","), [issues]);
  useEffect(() => {
    if (!keys) return;
    let alive = true;
    api.jiraViewed(keys.split(",")).then((s) => alive && setState(s), () => {});
    return () => {
      alive = false;
    };
  }, [keys]);
  useEffect(() => {
    const onViewed = (e: Event) => {
      const { key, at } = (e as CustomEvent<{ key: string; at: number }>).detail;
      setState((s) => s && { ...s, viewed: { ...s.viewed, [key]: at } });
    };
    window.addEventListener(VIEWED_EVENT, onViewed);
    return () => window.removeEventListener(VIEWED_EVENT, onViewed);
  }, []);
  return (issue) => {
    if (!state) return false;
    const seen = Math.max(state.viewed[issue.key] ?? state.baseline, ms(issue.lastViewed));
    return ms(issue.updated) > seen;
  };
}
