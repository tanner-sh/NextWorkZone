import { useEffect, useMemo, useState } from "react";
import { AtSign, BellRing, BookText, CheckCheck, CheckSquare, CircleDot, FilePen, MessageSquare, PencilLine, RefreshCw, Share2, ThumbsUp, UserRoundCheck, ArrowRightLeft, Bell, type LucideIcon } from "lucide-react";
import { errorMessage, type ActivityEvent, type ActivityKind } from "../../api";
import { Avatar, ErrorBox, NotConfigured, Skeleton, SysImg } from "../../components/common";
import { useContextMenu } from "../../components/ContextMenu";
import { action, activityTarget, detail, KIND_LABELS, loadNotifyKinds, markRead, pollActivity, storeNotifyKinds, useActivityFeed } from "../../lib/activity";
import { formatTime, parseTime } from "../../lib/format";
import { formatDay, today } from "../../lib/workspace";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";

const KIND_ICONS: Record<ActivityKind, LucideIcon> = {
  mention: AtSign,
  assigned: UserRoundCheck,
  created: CircleDot,
  comment: MessageSquare,
  status: ArrowRightLeft,
  field: PencilLine,
  edit: FilePen,
  share: Share2,
  task: CheckSquare,
  like: ThumbsUp,
  other: Bell,
};

/** 合并显示的时间范围。 */
const MERGE_MS = 10 * 60 * 1000;

type Filter = "all" | "unread" | "mention" | "comment" | "status" | "wiki";

const FILTERS: { id: Filter; label: string; match: (e: ActivityEvent) => boolean }[] = [
  { id: "all", label: "全部", match: () => true },
  { id: "unread", label: "未读", match: (e) => !e.read },
  { id: "mention", label: "@我", match: (e) => e.kind === "mention" || e.kind === "assigned" || e.kind === "task" },
  { id: "comment", label: "评论", match: (e) => e.kind === "comment" || e.kind === "mention" },
  { id: "status", label: "状态", match: (e) => e.kind === "status" },
  { id: "wiki", label: "Wiki", match: (e) => e.system === "wiki" },
];

/** 动态：与我有关的问题上别人的评论、状态变化、分配和修改，以及 Wiki 上的评论、提到和关注页面的修改。 */
export function ActivityPage() {
  const { isReady } = useSettings();
  const { navigate } = useNav();
  const feed = useActivityFeed();
  const [filter, setFilter] = useState<Filter>("all");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notifyKinds, setNotifyKinds] = useState(loadNotifyKinds);
  const settingsMenu = useContextMenu();

  const refresh = async () => {
    setLoading(true);
    setError(null);
    try {
      await pollActivity();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setLoading(false);
    }
  };

  const ready = isReady("jira") || isReady("confluence");
  // 打开页面时检查一次
  useEffect(() => {
    if (ready) void refresh();
  }, [ready]);

  const visible = useMemo(() => (feed?.events ?? []).filter(FILTERS.find((f) => f.id === filter)!.match), [feed, filter]);
  const days = useMemo(() => {
    const map = new Map<string, ActivityEvent[][]>();
    for (const e of visible) {
      const day = e.at.slice(0, 10);
      const groups = map.get(day) ?? [];
      // 同一个人几分钟内对同一问题的连续操作合并显示（中间可能夹着其他问题的动态）
      const group = groups.find((g) => {
        const prev = g[g.length - 1];
        return prev.issueKey === e.issueKey && prev.actor === e.actor && Math.abs(parseTime(prev.at).getTime() - parseTime(e.at).getTime()) <= MERGE_MS;
      });
      if (group) group.push(e);
      else groups.push([e]);
      map.set(day, groups);
    }
    return [...map.entries()];
  }, [visible]);

  if (!ready) {
    return (
      <section className="page">
        <NotConfigured label="Jira 或 Wiki" onOpenSettings={() => navigate({ page: "settings" })} />
      </section>
    );
  }

  const open = (group: ActivityEvent[]) => {
    const unread = group.filter((e) => !e.read).map((e) => e.id);
    if (unread.length > 0) void markRead(unread);
    const target = activityTarget(group[0]);
    if (target) navigate(target);
  };

  const toggleNotify = (kind: ActivityKind) => {
    const next = notifyKinds.includes(kind) ? notifyKinds.filter((k) => k !== kind) : [...notifyKinds, kind];
    setNotifyKinds(next);
    storeNotifyKinds(next);
  };

  const t = today();

  return (
    <section className="page activity-page">
      <header className="page-header">
        <div>
          <h1>动态</h1>
          <p className="muted small">
            你经办、报告、关注的问题和提到你的评论，以及 Wiki 上的评论、提到、分享和你关注的页面的修改。每 3 分钟检查一次
            {feed?.lastCheck && `，上次检查 ${formatTime(feed.lastCheck)}`}
          </p>
        </div>
        <span className="spacer" />
        <button className="btn subtle icon" title="通知设置" onClick={(e) => settingsMenu.open(e, [{ label: "以下动态发送系统通知", disabled: true }, ...(Object.keys(KIND_LABELS) as ActivityKind[]).map((k) => ({ label: KIND_LABELS[k], checked: notifyKinds.includes(k), onSelect: () => toggleNotify(k) }))])}>
          <BellRing size={15} />
        </button>
        <button className="btn subtle icon" title="立即检查" disabled={loading} onClick={refresh}>
          <RefreshCw size={15} className={loading ? "spin" : ""} />
        </button>
        <button className="btn" disabled={!feed?.unread} onClick={() => void markRead(null)}>
          <CheckCheck size={14} />
          全部已读
        </button>
      </header>
      <div className="segmented">
        {FILTERS.map((f) => (
          <button key={f.id} className={filter === f.id ? "active" : ""} onClick={() => setFilter(f.id)}>
            {f.label}
            {f.id === "unread" && feed && feed.unread > 0 && <span className="seg-count">{feed.unread}</span>}
          </button>
        ))}
      </div>
      {error && <ErrorBox message={error} onRetry={refresh} />}
      {!feed && <Skeleton lines={6} />}
      {feed && visible.length === 0 && <div className="empty-center muted activity-empty">{filter === "unread" ? "没有未读的动态" : "暂无动态"}</div>}
      {days.map(([day, events]) => (
        <div key={day} className="activity-day">
          <h3 className="muted small">
            {formatDay(day)}
            {formatDay(day) !== day && day !== t && <span className="faint"> · {day}</span>}
          </h3>
          <ul className="activity-list">
            {events.map((group) => {
              const first = group[0];
              return (
                <li key={first.id}>
                  <button className={`activity-item${group.some((e) => !e.read) ? " unread" : ""}`} onClick={() => open(group)}>
                    <Avatar name={first.actor} size={28} />
                    <div className="activity-main">
                      <div className="activity-line">
                        <strong>{first.actor}</strong>
                        <span className="activity-issue">
                          {first.system === "wiki" ? (
                            <>
                              <BookText size={14} className="muted" />
                              <span className="ellipsis">{first.issueSummary}</span>
                            </>
                          ) : (
                            <>
                              <SysImg service="jira" src={first.issueTypeIcon} className="icon16" />
                              <span className="issue-key">{first.issueKey}</span>
                              <span className="ellipsis">{first.issueSummary}</span>
                            </>
                          )}
                        </span>
                        <span className="spacer" />
                        <span className="muted small nowrap">{formatTime(first.at)}</span>
                      </div>
                      {/* 同一组按时间先后显示 */}
                      {[...group].reverse().map((e) => {
                        const Icon = KIND_ICONS[e.kind];
                        return (
                          <div key={e.id} className="activity-change">
                            <span className={`activity-kind kind-${e.kind}`}>
                              <Icon size={12} />
                              {action(e)}
                            </span>
                            {detail(e) && <span className="activity-text">{detail(e)}</span>}
                          </div>
                        );
                      })}
                    </div>
                  </button>
                </li>
              );
            })}
          </ul>
        </div>
      ))}
      {settingsMenu.menu}
    </section>
  );
}
