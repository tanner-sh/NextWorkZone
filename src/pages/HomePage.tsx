import { useEffect, useState } from "react";
import { api, errorMessage, type IssueSummary, type Project, type WeeklyView, type WikiRecent } from "../api";
import { ArrowRight, BookText, CheckCircle2, CircleDot, ClipboardList, Clock3, FolderGit2, GitPullRequest, Inbox, NotebookPen } from "lucide-react";
import { Skeleton, StatusPill, SysImg } from "../components/common";
import { formatTime } from "../lib/format";
import { reminderLabel, useReminders } from "../lib/reminders";
import { useNav } from "../state/nav";
import { useSettings } from "../state/settings";
import { useContextMenu } from "../components/ContextMenu";
import { useIssueMenu } from "./jira/issueMenu";
import { MY_UNRESOLVED_JQL } from "./jira/jql";
import { TodayTodos } from "./workspace/TodayTodos";
import { itemDetail, itemTarget, useInbox } from "../lib/inbox";
import { today } from "../lib/workspace";
import { clock, eventTarget, reportText, ReportDialog, timeline, WORK_ICONS } from "./workspace/WorkLog";

type Loadable<T> = { status: "loading" } | { status: "ok"; data: T } | { status: "error"; message: string } | { status: "off" };

function useLoad<T>(enabled: boolean, load: () => Promise<T>, cached?: () => Promise<T | null>): Loadable<T> {
  const [state, setState] = useState<Loadable<T>>(enabled ? { status: "loading" } : { status: "off" });
  useEffect(() => {
    if (!enabled) {
      setState({ status: "off" });
      return;
    }
    let cancelled = false;
    cached?.().then((data) => !cancelled && data && setState((s) => (s.status === "ok" ? s : { status: "ok", data })), () => {});
    load().then(
      (data) => !cancelled && setState({ status: "ok", data }),
      (e) => !cancelled && setState((s) => (s.status === "ok" ? s : { status: "error", message: errorMessage(e) })),
    );
    return () => {
      cancelled = true;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled]);
  return state;
}

export function HomePage() {
  const { isReady, settings } = useSettings();
  const { navigate } = useNav();
  const contextMenu = useContextMenu();
  /** 通过右键菜单修改过的问题，覆盖列表中的旧数据 */
  const [patched, setPatched] = useState<Record<string, IssueSummary>>({});
  const issueMenu = useIssueMenu((detail) => setPatched((p) => ({ ...p, [detail.key]: detail })));
  const reminders = useReminders();
  const reminderOf = new Map((reminders?.items ?? []).map((r, i) => [r.key, { ...r, rank: i }]));
  const dueCount = (reminders?.items ?? []).filter((r) => r.kind !== "stale").length;

  const issues = useLoad(isReady("jira"), () => api.jiraSearch(MY_UNRESOLVED_JQL), () => api.jiraCachedSearch(MY_UNRESOLVED_JQL));
  const weekly = useLoad(isReady("confluence") && Boolean(settings?.weeklyPageId), () => api.weeklyLoad());
  const projects = useLoad(isReady("gitlab"), () => api.glProjects(), () => api.glCachedProjects());
  const wikiRecent = useLoad(isReady("confluence"), () => api.wikiRecent(8));

  const now = new Date();
  const greeting = now.getHours() < 12 ? "上午好" : now.getHours() < 18 ? "下午好" : "晚上好";

  return (
    <section className="page">
      <header className="page-header">
        <div>
          <h1>{greeting}</h1>
          <p className="muted small">
            {now.getMonth() + 1} 月 {now.getDate()} 日 · 星期{"日一二三四五六"[now.getDay()]}
          </p>
        </div>
      </header>

      <div className="home-grid">
        <TodayTodos />
        <InboxCard />
        <div className="card home-card wide-card">
          <div className="card-title">
            <h2>
              <CircleDot size={16} className="muted" />
              我的未解决问题 {issues.status === "ok" && <span className="count">{issues.data.total}</span>}
              {dueCount > 0 && <span className="due-chip soon">{dueCount} 个快到期或已逾期</span>}
            </h2>
            <button className="btn subtle" onClick={() => navigate({ page: "jira" })}>
              全部 <ArrowRight size={14} />
            </button>
          </div>
          <CardBody state={issues} offLabel="Jira" onSettings={() => navigate({ page: "settings" })}>
            {(data) =>
              data.issues.length === 0 ? (
                <p className="muted">没有未解决的问题</p>
              ) : (
                <ul className="home-list">
                  {/* 需要提醒的问题排在前面 */}
                  {[...data.issues]
                    .sort((a, b) => (reminderOf.get(a.key)?.rank ?? 1e9) - (reminderOf.get(b.key)?.rank ?? 1e9))
                    .slice(0, 8)
                    .map((original: IssueSummary) => patched[original.key] ?? original)
                    .map((i) => (
                    <li key={i.key}>
                      <button
                        className={`home-row${contextMenu.target === i.key ? " menu-target" : ""}`}
                        onClick={() => navigate({ page: "jira", issueKey: i.key })}
                        onContextMenu={(e) => contextMenu.open(e, issueMenu.menuFor(i), i.key)}
                      >
                        <SysImg service="jira" src={i.issueType.iconUrl} className="icon16" />
                        <span className="issue-key">{i.key}</span>
                        <span className="ellipsis grow">{i.summary}</span>
                        {reminderOf.get(i.key) && <span className={`due-chip ${reminderOf.get(i.key)!.kind}`}>{reminderLabel(reminderOf.get(i.key)!.kind, reminderOf.get(i.key)!.days)}</span>}
                        <StatusPill status={i.status} />
                        <span className="muted small nowrap">{formatTime(i.updated)}</span>
                      </button>
                    </li>
                  ))}
                </ul>
              )
            }
          </CardBody>
        </div>

        <WorkLogCard />

        <div className="card home-card">
          <div className="card-title">
            <h2>
              <NotebookPen size={16} className="muted" />
              本周周报
            </h2>
            <button className="btn subtle" onClick={() => navigate({ page: "weekly" })}>
              去填写 <ArrowRight size={14} />
            </button>
          </div>
          <CardBody state={weekly} offLabel="Wiki 或周报页面" onSettings={() => navigate({ page: "settings" })}>
            {(data: WeeklyView) => <WeeklyStatus view={data} />}
          </CardBody>
        </div>

        <div className="card home-card">
          <div className="card-title">
            <h2>
              <BookText size={16} className="muted" />
              最近查看的 Wiki
            </h2>
            <button className="btn subtle" onClick={() => navigate({ page: "wiki" })}>
              全部 <ArrowRight size={14} />
            </button>
          </div>
          <CardBody state={wikiRecent} offLabel="Wiki" onSettings={() => navigate({ page: "settings" })}>
            {(data: WikiRecent[]) =>
              data.length === 0 ? (
                <p className="muted">还没有查看过 Wiki 页面</p>
              ) : (
                <ul className="home-list">
                  {data.slice(0, 6).map((p) => (
                    <li key={p.id}>
                      <button className="home-row" onClick={() => navigate({ page: "wiki", wikiPage: p.id })}>
                        <span className="ellipsis grow">
                          {p.title} <span className="muted small">{p.space}</span>
                        </span>
                        <span className="muted small nowrap">{formatTime(new Date(p.at).toISOString())}</span>
                      </button>
                    </li>
                  ))}
                </ul>
              )
            }
          </CardBody>
        </div>

        <div className="card home-card">
          <div className="card-title">
            <h2>
              <FolderGit2 size={16} className="muted" />
              最近活跃的项目
            </h2>
            <button className="btn subtle" onClick={() => navigate({ page: "gitlab" })}>
              全部 <ArrowRight size={14} />
            </button>
          </div>
          <CardBody state={projects} offLabel="GitLab" onSettings={() => navigate({ page: "settings" })}>
            {(data) => (
              <ul className="home-list">
                {data.slice(0, 6).map((p: Project) => (
                  <li key={p.id}>
                    <button className="home-row" onClick={() => navigate({ page: "gitlab", projectId: p.id })}>
                      <span className="ellipsis grow">
                        <strong>{p.name}</strong> <span className="muted small">{p.pathWithNamespace}</span>
                      </span>
                      <span className="muted small nowrap">{formatTime(p.lastActivityAt)}</span>
                    </button>
                  </li>
                ))}
              </ul>
            )}
          </CardBody>
        </div>
      </div>
      {contextMenu.menu}
      {issueMenu.dialogs}
    </section>
  );
}

/** 收件箱：需要处理的事（最多 5 条）。 */
function InboxCard() {
  const { navigate } = useNav();
  const inbox = useInbox();
  const items = inbox?.items ?? [];
  return (
    <div className="card home-card">
      <div className="card-title">
        <h2>
          <Inbox size={16} className="muted" />
          收件箱 {items.length > 0 && <span className="count">{items.length}</span>}
        </h2>
        <button className="btn subtle" onClick={() => navigate({ page: "inbox" })}>
          去处理 <ArrowRight size={14} />
        </button>
      </div>
      {!inbox ? (
        <Skeleton lines={3} />
      ) : items.length === 0 ? (
        <p className="muted small">没有需要处理的事。随时按快速记录快捷键把想到的事先记下来。</p>
      ) : (
        <ul className="home-list">
          {items.slice(0, 5).map((item) => {
            const Icon = item.source === "capture" ? Inbox : item.source === "due" ? Clock3 : item.source === "mr" ? GitPullRequest : item.system === "wiki" ? BookText : CircleDot;
            const target = itemTarget(item);
            return (
              <li key={item.id}>
                <button className="home-row" onClick={() => navigate(target ?? { page: "inbox" })}>
                  <Icon size={14} className={`muted inbox-mini source-${item.source}`} />
                  <span className="ellipsis grow">
                    {item.title || "无标题"} <span className="muted small">{itemDetail(item)}</span>
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      )}
    </div>
  );
}

/** 今天的工作记录：最近几件事，可直接生成日报。 */
function WorkLogCard() {
  const { navigate } = useNav();
  const day = today();
  const log = useLoad(true, () => api.wsWorklog(day));
  const [report, setReport] = useState<string | null>(null);
  return (
    <div className="card home-card">
      <div className="card-title">
        <h2>
          <ClipboardList size={16} className="muted" />
          今天的工作记录 {log.status === "ok" && log.data.events.length > 0 && <span className="count">{log.data.events.length}</span>}
        </h2>
        <span className="row-actions">
          <button className="btn subtle" disabled={log.status !== "ok"} onClick={() => log.status === "ok" && setReport(reportText(log.data))}>
            生成日报
          </button>
          <button className="btn subtle" onClick={() => navigate({ page: "notes", docId: `daily-${day}` })}>
            日记 <ArrowRight size={14} />
          </button>
        </span>
      </div>
      {log.status === "loading" && <Skeleton lines={3} />}
      {log.status === "error" && <p className="notice error">{log.message}</p>}
      {log.status === "ok" &&
        (log.data.events.length === 0 ? (
          <p className="muted small">今天还没有记录。Jira 上的流转和评论、代码推送、Wiki 编辑、完成的待办和计时会自动出现在这里。</p>
        ) : (
          <ul className="home-list">
            {timeline(log.data.events)
              .slice(-6)
              .reverse()
              .map(({ at, first, text }, i) => {
                const Icon = WORK_ICONS[first.system];
                const target = eventTarget(first);
                return (
                  <li key={`${at}-${i}`}>
                    <button className="home-row" onClick={() => target && navigate(target)} disabled={!target}>
                      <span className="muted small nowrap">{clock(at)}</span>
                      <Icon size={13} className={`muted worklog-icon system-${first.system}`} />
                      <span className="ellipsis grow">{text}</span>
                    </button>
                  </li>
                );
              })}
          </ul>
        ))}
      {report !== null && <ReportDialog day={day} text={report} onClose={() => setReport(null)} />}
    </div>
  );
}

function WeeklyStatus({ view }: { view: WeeklyView }) {
  const entry = view.entry;
  if (!view.currentWeekExists) return <p className="notice warn">本周（{view.currentWeekTitle}）的小节还没有创建。</p>;
  if (!entry?.rowFound) return <p className="notice warn">本周小节中没有找到「{view.personName}」的行。</p>;
  const filled = entry.content.length > 0;
  return (
    <div className="weekly-status">
      <span className={`big-state ${filled ? "ok" : "todo"}`}>{filled ? <CheckCircle2 size={22} /> : <Clock3 size={22} />}</span>
      <div>
        <div className="stat-title">{filled ? "已填写" : "未填写"}</div>
        <div className="muted small">
          {entry.sectionTitle} · {filled ? `${entry.content.filter((i) => i.level === 0).length} 个分组，${entry.content.length} 条` : "可以从 Jira 和 GitLab 生成草稿"}
        </div>
      </div>
    </div>
  );
}

function CardBody<T>({ state, offLabel, onSettings, children }: { state: Loadable<T>; offLabel: string; onSettings: () => void; children: (data: T) => React.ReactNode }) {
  switch (state.status) {
    case "loading":
      return <Skeleton lines={3} />;
    case "error":
      return <p className="notice error">{state.message}</p>;
    case "off":
      return (
        <p className="muted">
          尚未配置 {offLabel}。
          <button className="link" onClick={onSettings}>
            去设置
          </button>
        </p>
      );
    case "ok":
      return <>{children(state.data)}</>;
  }
}
