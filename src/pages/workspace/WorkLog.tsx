import { useCallback, useEffect, useState } from "react";
import { BookText, CheckSquare, ChevronDown, ChevronRight, CircleDot, ClipboardList, Copy, FileText, GitBranch, RefreshCw, Timer } from "lucide-react";
import { api, errorMessage, type Doc, type WorkEvent, type WorkLog } from "../../api";
import { Modal, Skeleton } from "../../components/common";
import { toast } from "../../components/Toast";
import { copyText } from "../../lib/clipboard";
import { weekdayOf, workspaceChanged } from "../../lib/workspace";
import { useNav, type NavTarget } from "../../state/nav";
import { docInput } from "./docMenu";

const SECTION = "## 工作记录";

const pad = (n: number) => String(n).padStart(2, "0");
export const clock = (ms: number) => `${pad(new Date(ms).getHours())}:${pad(new Date(ms).getMinutes())}`;

/** 时长，例如 1h 25m。 */
function duration(ms: number): string {
  const minutes = Math.max(1, Math.round(ms / 60000));
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  return [h && `${h}h`, m && `${m}m`].filter(Boolean).join(" ");
}

const KIND_TEXT: Record<string, string> = {
  create: "创建",
  transition: "流转",
  comment: "评论",
  assign: "分配",
  update: "修改",
  push: "推送",
  mr_open: "发起合并请求",
  mr_merge: "合并",
  mr_approve: "批准",
  mr_close: "关闭合并请求",
  edit: "修改页面",
  done: "完成待办",
  timer: "计时",
};

/** 一件事的一行说明（时间线中显示）。 */
function eventText(e: WorkEvent): string {
  const action = e.system === "wiki" && e.kind === "create" ? "新建页面" : e.system === "wiki" && e.kind === "comment" ? "评论页面" : KIND_TEXT[e.kind] ?? e.kind;
  const subject = e.system === "jira" ? `${e.key} ${e.title}` : e.system === "gitlab" && e.key ? `${e.title} ${e.key}` : e.title;
  const detail = e.durationMs ? duration(e.durationMs) : e.detail;
  return `${action} · ${subject}${detail ? `：${detail}` : ""}`;
}

/** 同一个问题上的几件事合成一句，例如“FYX-1 概要：处理中 → 已解决；评论 1 条；修改了附件”。 */
function describeJira(list: WorkEvent[]): string {
  const parts: string[] = [];
  for (const e of list) {
    if (e.kind === "transition") parts.push(e.detail);
    else if (e.kind === "create") parts.push("新建");
    else if (e.kind === "assign") parts.push(e.detail);
  }
  const comments = list.filter((e) => e.kind === "comment");
  if (comments.length === 1) parts.push(`评论：${comments[0].detail}`);
  else if (comments.length > 1) parts.push(`评论 ${comments.length} 条`);
  const fields = [...new Set(list.filter((e) => e.kind === "update").flatMap((e) => e.detail.replace(/^修改了/, "").split("、")))];
  if (fields.length) parts.push(`修改了${fields.join("、")}`);
  return `${list[0].key} ${list[0].title}${parts.length ? `：${[...new Set(parts)].join("；")}` : ""}`;
}

/** 同一个项目上的推送、合并请求、评论合成一句。 */
function describeCode(list: WorkEvent[]): string {
  const parts: string[] = [];
  const pushes = list.filter((e) => e.kind === "push");
  if (pushes.length) {
    const commits = [...new Set(pushes.map((e) => e.detail.replace(/（[^（）]*）$/, "")))].filter(Boolean);
    parts.push(`提交：${commits.slice(0, 5).join("；")}${commits.length > 5 ? ` 等 ${commits.length} 项` : ""}`);
  }
  for (const kind of ["mr_open", "mr_merge", "mr_approve", "mr_close"]) {
    const mrs = [...new Set(list.filter((e) => e.kind === kind).map((e) => `${e.key} ${e.detail}`.trim()))];
    if (mrs.length) parts.push(`${KIND_TEXT[kind]} ${mrs.join("、")}`);
  }
  const comments = list.filter((e) => e.kind === "comment").length;
  if (comments) parts.push(`评论 ${comments} 条`);
  return `${list[0].title}：${parts.join("；")}`;
}

function describeWiki(list: WorkEvent[]): string {
  const kinds = new Set(list.map((e) => e.kind));
  const action = [kinds.has("create") ? "新建" : kinds.has("edit") ? "更新" : "", kinds.has("comment") ? "评论" : ""].filter(Boolean).join("并");
  return `${action}页面：${list[0].title}`;
}

/**
 * 按对象整理成日报：Jira 问题按问题、代码按项目、Wiki 按页面合并，待办、计时各列一组。
 * 返回分组标题和条目，写入日记和生成日报共用。
 */
export function summarize(log: WorkLog): { title: string; items: string[] }[] {
  const groups: { title: string; items: string[] }[] = [];
  const byKey = <T,>(list: WorkEvent[], key: (e: WorkEvent) => string, render: (events: WorkEvent[]) => T) => {
    const map = new Map<string, WorkEvent[]>();
    for (const e of list) map.set(key(e), [...(map.get(key(e)) ?? []), e]);
    return [...map.values()].map(render);
  };
  const events = log.events;

  const jira = byKey(events.filter((e) => e.system === "jira"), (e) => e.key ?? e.title, describeJira);
  if (jira.length) groups.push({ title: "Jira 问题", items: jira });
  const code = byKey(events.filter((e) => e.system === "gitlab"), (e) => e.title, describeCode);
  if (code.length) groups.push({ title: "代码", items: code });
  const wiki = byKey(events.filter((e) => e.system === "wiki"), (e) => e.key ?? e.title, describeWiki);
  if (wiki.length) groups.push({ title: "Wiki", items: wiki });

  const todos = [...new Set(events.filter((e) => e.system === "todo").map((e) => e.title))].filter(Boolean);
  if (todos.length) groups.push({ title: "完成的待办", items: todos });

  const timers = byKey(
    events.filter((e) => e.system === "timer"),
    (e) => e.title,
    (list) => ({ title: list[0].title, ms: list.reduce((sum, e) => sum + (e.durationMs ?? 0), 0) }),
  );
  if (timers.length) {
    const total = timers.reduce((sum, t) => sum + t.ms, 0);
    groups.push({ title: `计时（合计 ${duration(total)}）`, items: timers.map((t) => `${t.title}：${duration(t.ms)}`) });
  }
  return groups;
}

/** 日报正文（纯文本，可以直接粘贴到聊天工具或 Wiki）。 */
export function reportText(log: WorkLog): string {
  const groups = summarize(log);
  const lines = [`${log.day} ${weekdayOf(log.day)} 工作日报`, ""];
  groups.forEach((g, i) => {
    lines.push(`${"一二三四五六七八"[i] ?? i + 1}、${g.title}`);
    g.items.forEach((item, n) => lines.push(`${n + 1}. ${item}`));
    lines.push("");
  });
  if (groups.length === 0) lines.push("（没有找到当天的工作记录）");
  return lines.join("\n").trim();
}

/** 把日记中的“工作记录”小节替换为最新内容（没有时追加到末尾）。 */
export function withWorkSection(content: string, log: WorkLog): string {
  const body = summarize(log)
    .map((g) => [`**${g.title}**`, ...g.items.map((i) => `- ${i}`)].join("\n"))
    .join("\n\n");
  const section = `${SECTION}\n\n${body || "（没有找到当天的工作记录）"}\n`;
  const start = content.indexOf(SECTION);
  if (start < 0) return content.trim() ? `${content.replace(/\s+$/, "")}\n\n${section}` : section;
  const rest = content.slice(start + SECTION.length);
  const next = rest.search(/\n#{1,2} /);
  return `${content.slice(0, start)}${section}${next >= 0 ? rest.slice(next) : ""}`;
}

/** 连续几分钟内对同一个对象做的事合成时间线中的一行（例如一次流转同时改了几个字段）。 */
const MERGE_MS = 5 * 60_000;

export function timeline(events: WorkEvent[]): { at: number; first: WorkEvent; text: string }[] {
  const rows: WorkEvent[][] = [];
  for (const e of events) {
    const last = rows[rows.length - 1];
    const prev = last?.[last.length - 1];
    const same = prev && prev.system === e.system && prev.title === e.title && prev.key === e.key && e.at - prev.at <= MERGE_MS;
    if (same && (e.system === "jira" || e.system === "gitlab" || e.system === "wiki")) last.push(e);
    else rows.push([e]);
  }
  return rows.map((list) => {
    const first = list[0];
    const text =
      list.length === 1 ? eventText(first) : first.system === "jira" ? describeJira(list) : first.system === "gitlab" ? describeCode(list) : describeWiki(list);
    return { at: first.at, first, text };
  });
}

export function eventTarget(e: WorkEvent): NavTarget | null {
  if (e.system === "jira" && e.key) return { page: "jira", issueKey: e.key };
  if ((e.system === "todo" || e.system === "timer") && e.key) return { page: "jira", issueKey: e.key };
  if (e.system === "wiki" && e.key) return { page: "wiki", wikiPage: e.key };
  if (e.system === "gitlab" && e.projectId) {
    const iid = e.key?.startsWith("!") ? Number(e.key.slice(1)) : NaN;
    return Number.isInteger(iid) ? { page: "gitlab", projectId: e.projectId, mrIid: iid } : { page: "gitlab", projectId: e.projectId };
  }
  return null;
}

export const WORK_ICONS = { jira: CircleDot, gitlab: GitBranch, wiki: BookText, todo: CheckSquare, timer: Timer } as const;

/** 日记下方的工作记录：当天在各处做过的事，可写入日记、生成日报。 */
export function WorkLogPanel({ doc }: { doc: Doc }) {
  const { navigate } = useNav();
  const day = doc.day!;
  const [log, setLog] = useState<WorkLog | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [open, setOpen] = useState(true);
  const [report, setReport] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      setLog(await api.wsWorklog(day));
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setLoading(false);
    }
  }, [day]);
  useEffect(() => {
    void load();
  }, [load]);

  const writeToDaily = async () => {
    if (!log) return;
    try {
      const latest = await api.wsDaily(day);
      // 保存后日记面板随 workspaceChanged 重新加载
      await api.wsSaveDoc(docInput(latest, { kind: "daily", title: latest.title || day, content: withWorkSection(latest.content, log) }));
      workspaceChanged();
      toast("已写入日记的“工作记录”");
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  return (
    <section className="block worklog">
      <div className="worklog-head">
        <button className="section-toggle" onClick={() => setOpen((v) => !v)}>
          {open ? <ChevronDown size={14} /> : <ChevronRight size={14} />}
          <ClipboardList size={15} />
          工作记录 {log && log.events.length > 0 && <span className="count">{log.events.length}</span>}
        </button>
        <span className="spacer" />
        <button className="btn subtle icon" title="刷新" onClick={load} disabled={loading}>
          <RefreshCw size={14} className={loading ? "spin" : ""} />
        </button>
        <button className="btn small-btn" disabled={!log || log.events.length === 0} onClick={writeToDaily} title="把整理后的工作记录写入（或更新）日记中的“工作记录”小节">
          <FileText size={13} />
          写入日记
        </button>
        <button className="btn small-btn primary" disabled={!log} onClick={() => log && setReport(reportText(log))}>
          <ClipboardList size={13} />
          生成日报
        </button>
      </div>
      {open && (
        <>
          {error && <p className="notice error small">{error}</p>}
          {log?.notes.map((n) => (
            <p key={n} className="muted small">
              {n}
            </p>
          ))}
          {!log && !error && <Skeleton lines={3} />}
          {log && log.events.length === 0 && <p className="muted small">这一天还没有记录：Jira 上的流转和评论、GitLab 推送和合并请求、Wiki 编辑、完成的待办和计时都会出现在这里。</p>}
          <ul className="worklog-list">
            {log &&
              timeline(log.events).map(({ at, first, text }, i) => {
                const Icon = WORK_ICONS[first.system];
                const target = eventTarget(first);
                return (
                  <li key={`${at}-${i}`}>
                    <span className="muted small worklog-time">{clock(at)}</span>
                    <Icon size={13} className={`muted worklog-icon system-${first.system}`} />
                    {target ? (
                      <button className="link-plain ellipsis grow" onClick={() => navigate(target)} title={text}>
                        {text}
                      </button>
                    ) : (
                      <span className="ellipsis grow" title={text}>
                        {text}
                      </span>
                    )}
                  </li>
                );
              })}
          </ul>
        </>
      )}
      {report !== null && <ReportDialog day={day} text={report} onClose={() => setReport(null)} />}
    </section>
  );
}

export function ReportDialog({ day, text, onClose }: { day: string; text: string; onClose: () => void }) {
  const [value, setValue] = useState(text);
  return (
    <Modal
      title={`日报 · ${day}`}
      onClose={onClose}
      footer={
        <>
          <span className="muted small grow">可以先修改再复制</span>
          <button className="btn" onClick={onClose}>
            关闭
          </button>
          <button
            className="btn primary"
            onClick={() =>
              void copyText(value).then(() => {
                toast("日报已复制");
                onClose();
              })
            }
          >
            <Copy size={14} />
            复制
          </button>
        </>
      }
    >
      <textarea className="report-text" rows={16} value={value} onChange={(e) => setValue(e.target.value)} />
    </Modal>
  );
}
