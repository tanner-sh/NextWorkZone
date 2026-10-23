// Jira 动态：定期检查、通知设置，以及各页面共享的未读数。
import { useEffect, useState } from "react";
import { api, type ActivityEvent, type ActivityFeed, type ActivityKind } from "../api";
import { notify } from "./notify";
import type { NavTarget } from "../state/nav";

/** 检查动态的间隔。 */
export const ACTIVITY_INTERVAL_MS = 3 * 60 * 1000;

export const KIND_LABELS: Record<ActivityKind, string> = {
  mention: "提到我",
  assigned: "分配给我",
  created: "新问题",
  comment: "评论",
  status: "状态变化",
  field: "字段修改",
  edit: "Wiki 页面修改",
  share: "Wiki 分享",
  task: "Wiki 任务",
  like: "Wiki 点赞",
  other: "其他 Wiki 通知",
};

const NOTIFY_KEY = "nextworkzone.activity.notify";
/** 默认不通知字段修改（截止日期等变化较频繁） */
const DEFAULT_NOTIFY: ActivityKind[] = ["mention", "assigned", "created", "comment", "status", "share", "task"];

export function loadNotifyKinds(): ActivityKind[] {
  try {
    const saved = localStorage.getItem(NOTIFY_KEY);
    return saved ? (JSON.parse(saved) as ActivityKind[]) : DEFAULT_NOTIFY;
  } catch {
    return DEFAULT_NOTIFY;
  }
}

export function storeNotifyKinds(kinds: ActivityKind[]) {
  try {
    localStorage.setItem(NOTIFY_KEY, JSON.stringify(kinds));
  } catch {
    // 不保存
  }
}

const FEED_EVENT = "nextworkzone-activity-feed";

/** 动态数据有变化（检查、标为已读）时通知各界面。 */
export function publishFeed(feed: ActivityFeed) {
  window.dispatchEvent(new CustomEvent(FEED_EVENT, { detail: feed }));
}

/** 当前的动态列表；`null` 表示尚未加载。 */
export function useActivityFeed(): ActivityFeed | null {
  const [feed, setFeed] = useState<ActivityFeed | null>(null);
  useEffect(() => {
    api.jiraActivity().then(setFeed, () => {});
    const onFeed = (e: Event) => setFeed((e as CustomEvent<ActivityFeed>).detail);
    window.addEventListener(FEED_EVENT, onFeed);
    return () => window.removeEventListener(FEED_EVENT, onFeed);
  }, []);
  return feed;
}

/** 检查一次动态，按通知设置发送系统通知。 */
export async function pollActivity(): Promise<ActivityFeed> {
  const { feed, fresh } = await api.jiraActivityPoll();
  publishFeed(feed);
  const kinds = loadNotifyKinds();
  const wanted = fresh.filter((e) => kinds.includes(e.kind));
  if (wanted.length === 1) {
    const e = wanted[0];
    void notify(subject(e), `${e.actor} ${action(e)}${detail(e) ? `：${detail(e)}` : ""}`);
  } else if (wanted.length > 1) {
    const items = [...new Set(wanted.map((e) => (e.system === "wiki" ? e.issueSummary : e.issueKey)))];
    const system = wanted.every((e) => e.system === "wiki") ? "Wiki " : wanted.every((e) => e.system !== "wiki") ? "Jira " : "";
    void notify(`${wanted.length} 条新的${system}动态`, `${items.slice(0, 4).join("、")}${items.length > 4 ? ` 等 ${items.length} 项` : ""}`);
  }
  return feed;
}

export async function markRead(ids: string[] | null) {
  publishFeed(await api.jiraActivityRead(ids));
}

/** 动态对应的问题或页面。 */
export function subject(e: ActivityEvent): string {
  return e.system === "wiki" ? e.issueSummary : `${e.issueKey} ${e.issueSummary}`;
}

/** 动态的动作，例如“评论”“修改了状态”。 */
export function action(e: ActivityEvent): string {
  if (e.system === "wiki") {
    switch (e.kind) {
      case "mention":
        return "在 Wiki 中提到了你";
      case "comment":
        return "评论了页面";
      case "edit":
        return "修改了页面";
      case "share":
        return "分享了页面";
      case "task":
        return "给你分配了任务";
      case "like":
        return "赞了";
      default:
        return "";
    }
  }
  switch (e.kind) {
    case "mention":
      return "在评论中提到了你";
    case "comment":
      return "评论";
    case "status":
      return "修改了状态";
    case "assigned":
      return "把问题分配给你";
    case "created":
      return e.text;
    default:
      return "修改了";
  }
}

/** 动态的详细内容（评论摘要、状态变化等）；动作已说明全部信息时为空。 */
export function detail(e: ActivityEvent): string {
  return e.kind === "assigned" || e.kind === "created" ? "" : e.text;
}

/** 动态的跳转目标。 */
export function activityTarget(e: ActivityEvent): NavTarget | null {
  if (e.system === "wiki") return e.issueKey ? { page: "wiki", wikiPage: e.issueKey } : null;
  return { page: "jira", issueKey: e.issueKey };
}
