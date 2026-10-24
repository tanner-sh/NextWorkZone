import { useCallback, useEffect, useRef, useState } from "react";
import { ArrowRight, Clock, Copy, GitCommitHorizontal, History, Link, Lock, MessageSquare, Pencil, Plus, Reply, Trash2 } from "lucide-react";
import { api, errorMessage, type Comment, type CommentLevel, type CommentVisibility, type HistoryEntry, type IssueDetail, type Worklog } from "../../api";
import type { MenuInput } from "../../components/ContextMenu";
import { contributeMenu } from "../../components/MenuHost";
import { RichHtml } from "../../components/RichHtml";
import { guarded, toast } from "../../components/Toast";
import { copyText } from "../../lib/clipboard";
import { useSettings } from "../../state/settings";
import { Avatar, ErrorBox, Skeleton } from "../../components/common";
import { formatTime, localizeDuration } from "../../lib/format";
import { toJiraDateTime } from "./fieldForm";
import { parseTime } from "../../lib/format";
import { CommentTemplateButton } from "./templates";
import { referencedImages, WikiEditor, type PendingImage } from "./wiki/WikiEditor";

type Tab = "comments" | "worklogs" | "history" | "flow";

/** 详情底部的活动区：评论、工作日志、变更历史。`newSince` 之后别人的评论标为新评论。 */
export function IssueActivity({ issue, newSince, onCommentsChanged, onTimeChanged }: { issue: IssueDetail; newSince: number | null; onCommentsChanged: (comments: Comment[]) => void; onTimeChanged: () => void }) {
  const [tab, setTab] = useState<Tab>("comments");
  return (
    <section className="block">
      <div className="segmented activity-tabs">
        <button className={tab === "comments" ? "active" : ""} onClick={() => setTab("comments")}>
          <MessageSquare size={14} />
          评论 {issue.comments.length > 0 && <span className="muted">{issue.comments.length}</span>}
        </button>
        <button className={tab === "worklogs" ? "active" : ""} onClick={() => setTab("worklogs")}>
          <Clock size={14} />
          工作日志 {issue.timeTracking?.timeSpent && <span className="muted">{issue.timeTracking.timeSpent}</span>}
        </button>
        <button className={tab === "history" ? "active" : ""} onClick={() => setTab("history")}>
          <History size={14} />
          历史记录
        </button>
        <button className={tab === "flow" ? "active" : ""} onClick={() => setTab("flow")} title="每次状态流转，以及在各状态停留的时间">
          <GitCommitHorizontal size={14} />
          流转记录
        </button>
      </div>
      {tab === "comments" && <Comments issue={issue} newSince={newSince} onChange={onCommentsChanged} />}
      {tab === "worklogs" && <Worklogs issueKey={issue.key} onChanged={onTimeChanged} />}
      {tab === "history" && <HistoryList issueKey={issue.key} created={issue.created} reporter={issue.reporter} />}
      {tab === "flow" && <StatusFlow issue={issue} />}
    </section>
  );
}

function Comments({ issue, newSince, onChange }: { issue: IssueDetail; newSince: number | null; onChange: (comments: Comment[]) => void }) {
  const [draft, setDraft] = useState("");
  const [visibility, setVisibility] = useState<CommentVisibility | null>(null);
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [images, setImages] = useState<PendingImage[]>([]);
  const composer = useRef<HTMLDivElement>(null);

  const send = async () => {
    if (!draft.trim()) return;
    setSending(true);
    setError(null);
    try {
      const used = referencedImages(images, [draft]);
      if (used.length > 0) await api.jiraUploadAttachments(issue.key, used.map((img) => img.path));
      const added = await api.jiraAddComment(issue.key, draft.trim(), visibility);
      onChange([...issue.comments, added]);
      setDraft("");
      setImages([]);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setSending(false);
    }
  };

  /** 引用评论原文并提及作者。 */
  const quote = (c: Comment) => {
    const quoted = `{quote}\n${c.body.trim()}\n{quote}\n${c.authorName ? `[~${c.authorName}] ` : ""}`;
    setDraft((d) => (d.trim() ? `${d.trimEnd()}\n\n${quoted}` : quoted));
    composer.current?.scrollIntoView({ behavior: "smooth", block: "center" });
  };

  return (
    <>
      {issue.comments.length === 0 && <p className="muted small">暂无评论</p>}
      <ol className="comments">
        {issue.comments.map((c) => (
          <CommentItem
            key={c.id}
            issueKey={issue.key}
            comment={c}
            isNew={newSince !== null && !c.mine && parseTime(c.created).getTime() > newSince}
            onQuote={() => quote(c)}
            onUpdated={(updated) => onChange(issue.comments.map((x) => (x.id === updated.id ? updated : x)))}
            onDeleted={() => onChange(issue.comments.filter((x) => x.id !== c.id))}
          />
        ))}
      </ol>
      <div className="composer" ref={composer}>
        <WikiEditor
          value={draft}
          onChange={setDraft}
          issueKey={issue.key}
          onImage={(img) => setImages((list) => [...list, img])}
          minHeight={72}
          placeholder="添加评论（Ctrl+Enter 发送，输入 @ 提及同事）"
          onSubmitShortcut={() => void send()}
          footer={
            <>
              <VisibilitySelect issueKey={issue.key} value={visibility} onChange={setVisibility} />
              <CommentTemplateButton issue={issue} draft={draft} onInsert={(text) => setDraft((d) => (d.trim() ? `${d.trimEnd()}\n\n${text}` : text))} />
              <button className="btn primary" disabled={!draft.trim() || sending} onClick={send}>
                {sending ? "发送中…" : "发送评论"}
              </button>
            </>
          }
        />
        {error && <ErrorBox message={error} />}
      </div>
    </>
  );
}

function CommentItem({ issueKey, comment: c, isNew, onQuote, onUpdated, onDeleted }: { issueKey: string; comment: Comment; isNew: boolean; onQuote: () => void; onUpdated: (c: Comment) => void; onDeleted: () => void }) {
  const [editing, setEditing] = useState<string | null>(null);
  const [images, setImages] = useState<PendingImage[]>([]);
  const [confirming, setConfirming] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const save = async () => {
    if (editing === null || !editing.trim()) return;
    setBusy(true);
    setError(null);
    try {
      const used = referencedImages(images, [editing]);
      if (used.length > 0) await api.jiraUploadAttachments(issueKey, used.map((img) => img.path));
      // 保持原来的可见范围
      onUpdated(await api.jiraUpdateComment(issueKey, c.id, editing.trim(), c.visibility));
      setEditing(null);
      setImages([]);
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const remove = async () => {
    setBusy(true);
    setError(null);
    try {
      await api.jiraDeleteComment(issueKey, c.id);
      onDeleted();
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
      setConfirming(false);
    }
  };

  const jiraBase = useSettings().baseUrl("jira");
  const copy = (text: string) =>
    guarded(async () => {
      await copyText(text);
      toast("已复制");
    });
  const commentActions: MenuInput[] = [
    { label: "引用回复", icon: <Reply size={14} />, onSelect: onQuote },
    c.mine && { label: "编辑", icon: <Pencil size={14} />, onSelect: () => setEditing(c.body) },
    "separator",
    { label: "复制评论内容", icon: <Copy size={14} />, onSelect: copy(c.body) },
    { label: "复制评论链接", icon: <Link size={14} />, onSelect: copy(`${jiraBase}/browse/${issueKey}?focusedCommentId=${c.id}#comment-${c.id}`) },
    c.mine && "separator",
    c.mine && { label: "删除", icon: <Trash2 size={14} />, danger: true, onSelect: () => setConfirming(true) },
  ];

  // 编辑过的评论（修改时间比创建时间晚一分钟以上）
  const edited = new Date(c.updated).getTime() - new Date(c.created).getTime() > 60_000;

  return (
    <li className={`comment${isNew ? " new" : ""}`} id={`comment-${c.id}`} onContextMenu={(e) => editing === null && contributeMenu(e, { label: "评论", items: commentActions })}>
      <Avatar name={c.author} size={28} />
      <div className="comment-card">
        <div className="comment-meta">
          <strong>{c.author}</strong>
          {isNew && <span className="new-badge">新</span>}
          {c.visibility && (
            <span className="restricted-badge" title={`这条评论仅「${c.visibility.value}」${c.visibility.type === "role" ? "角色" : "组"}的成员可见`}>
              <Lock size={11} />
              仅 {c.visibility.value} 可见
            </span>
          )}
          <span className="muted small" title={edited ? `修改于 ${formatTime(c.updated)}` : undefined}>
            {formatTime(c.created)}
            {edited && "（已编辑）"}
          </span>
          <span className="spacer" />
          {editing === null && (
            <span className="comment-actions">
              {confirming ? (
                <span className="inline-confirm">
                  <button className="btn danger small-btn" disabled={busy} onClick={remove}>
                    确认删除
                  </button>
                  <button className="btn small-btn" onClick={() => setConfirming(false)}>
                    取消
                  </button>
                </span>
              ) : (
                <>
                  <button className="btn subtle icon" title="引用回复" onClick={onQuote}>
                    <Reply size={14} />
                  </button>
                  {c.mine && (
                    <>
                      <button className="btn subtle icon" title="编辑" onClick={() => setEditing(c.body)}>
                        <Pencil size={14} />
                      </button>
                      <button className="btn subtle icon" title="删除" onClick={() => setConfirming(true)}>
                        <Trash2 size={14} />
                      </button>
                    </>
                  )}
                </>
              )}
            </span>
          )}
        </div>
        {editing === null ? (
          <RichHtml service="jira" html={c.bodyHtml} />
        ) : (
          <WikiEditor
            value={editing}
            onChange={setEditing}
            issueKey={issueKey}
            onImage={(img) => setImages((list) => [...list, img])}
            minHeight={72}
            onSubmitShortcut={() => void save()}
            footer={
              <>
                <button className="btn" onClick={() => setEditing(null)}>
                  取消
                </button>
                <button className="btn primary" disabled={busy || !editing.trim()} onClick={save}>
                  {busy ? "保存中…" : "保存"}
                </button>
              </>
            }
          />
        )}
        {error && <ErrorBox message={error} />}
      </div>
    </li>
  );
}

/** 评论的可见范围：所有用户或某个项目角色、用户组。选项来自网页表单，没有网页登录时不显示。 */
export function VisibilitySelect({ issueKey, value, onChange }: { issueKey: string; value: CommentVisibility | null; onChange: (v: CommentVisibility | null) => void }) {
  const [levels, setLevels] = useState<CommentLevel[]>([]);
  useEffect(() => {
    api.jiraCommentLevels(issueKey).then(setLevels, () => setLevels([]));
  }, [issueKey]);
  if (levels.length === 0) return null;
  const current = value ? levels.findIndex((l) => l.visibility.type === value.type && l.visibility.value === value.value) : -1;
  return (
    <select
      className={`visibility-select${value ? " restricted" : ""}`}
      value={current}
      title="评论的可见范围"
      onChange={(e) => {
        const i = Number(e.target.value);
        onChange(i >= 0 ? levels[i].visibility : null);
      }}
    >
      <option value={-1}>所有用户可见</option>
      {levels.map((l, i) => (
        <option key={i} value={i}>
          仅 {l.label} 可见
        </option>
      ))}
    </select>
  );
}

// ---------- 工作日志 ----------

function Worklogs({ issueKey, onChanged }: { issueKey: string; onChanged: () => void }) {
  const [logs, setLogs] = useState<Worklog[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  /** 正在编辑的工作日志；`"new"` 表示新增。 */
  const [editing, setEditing] = useState<Worklog | "new" | null>(null);
  const [confirming, setConfirming] = useState<string | null>(null);

  const load = useCallback(async () => {
    setError(null);
    try {
      setLogs(await api.jiraWorklogs(issueKey));
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [issueKey]);

  useEffect(() => {
    void load();
  }, [load]);

  const remove = async (id: string) => {
    setError(null);
    try {
      setLogs(await api.jiraDeleteWorklog(issueKey, id));
      onChanged();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setConfirming(null);
    }
  };

  return (
    <>
      {error && <ErrorBox message={error} onRetry={load} />}
      {!logs && !error && <Skeleton lines={3} />}
      {logs && logs.length === 0 && editing !== "new" && <p className="muted small">暂无工作日志</p>}
      {logs && logs.length > 0 && (
        <ol className="worklogs">
          {logs.map((w) =>
            editing !== "new" && editing?.id === w.id ? (
              <li key={w.id}>
                <WorklogForm
                  issueKey={issueKey}
                  worklog={w}
                  onCancel={() => setEditing(null)}
                  onSaved={(list) => {
                    setLogs(list);
                    setEditing(null);
                    onChanged();
                  }}
                />
              </li>
            ) : (
              <li key={w.id} className="worklog">
                <Avatar name={w.author} size={24} />
                <div className="grow">
                  <div className="comment-meta">
                    <strong>{w.author}</strong>
                    <span className="muted small">记录了</span>
                    <strong>{localizeDuration(w.timeSpent)}</strong>
                    <span className="muted small">· 开始于 {formatTime(w.started)}</span>
                  </div>
                  {w.comment && <div className="pre-wrap">{w.comment}</div>}
                </div>
                {w.mine &&
                  (confirming === w.id ? (
                    <span className="inline-confirm">
                      <button className="btn danger small-btn" onClick={() => remove(w.id)}>
                        删除
                      </button>
                      <button className="btn small-btn" onClick={() => setConfirming(null)}>
                        取消
                      </button>
                    </span>
                  ) : (
                    <span className="row-actions">
                      <button className="btn subtle icon" title="修改" onClick={() => setEditing(w)}>
                        <Pencil size={14} />
                      </button>
                      <button className="btn subtle icon" title="删除" onClick={() => setConfirming(w.id)}>
                        <Trash2 size={14} />
                      </button>
                    </span>
                  ))}
              </li>
            ),
          )}
        </ol>
      )}
      {editing === "new" ? (
        <WorklogForm
          issueKey={issueKey}
          worklog={null}
          onCancel={() => setEditing(null)}
          onSaved={(list) => {
            setLogs(list);
            setEditing(null);
            onChanged();
          }}
        />
      ) : (
        <div>
          <button className="btn" onClick={() => setEditing("new")}>
            <Plus size={14} />
            记录工作
          </button>
        </div>
      )}
    </>
  );
}

const pad = (n: number) => String(n).padStart(2, "0");

function nowLocal(): string {
  const d = new Date();
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function WorklogForm({ issueKey, worklog, onCancel, onSaved }: { issueKey: string; worklog: Worklog | null; onCancel: () => void; onSaved: (list: Worklog[]) => void }) {
  const [started, setStarted] = useState(worklog ? worklog.started.slice(0, 16) : nowLocal());
  const [timeSpent, setTimeSpent] = useState(worklog?.timeSpent ?? "");
  const [comment, setComment] = useState(worklog?.comment ?? "");
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const save = async () => {
    setSaving(true);
    setError(null);
    try {
      onSaved(await api.jiraSaveWorklog(issueKey, worklog?.id ?? null, { started: toJiraDateTime(started), timeSpent: timeSpent.trim(), comment }));
    } catch (e) {
      setError(errorMessage(e));
      setSaving(false);
    }
  };

  return (
    <div className="inline-form">
      <div className="form-grid">
        <label className="form-field">
          <span>
            耗费时间<em className="required">*</em>
          </span>
          <input autoFocus value={timeSpent} placeholder="例如 3h 30m、1d" onChange={(e) => setTimeSpent(e.target.value)} />
        </label>
        <label className="form-field">
          <span>
            开始时间<em className="required">*</em>
          </span>
          <input type="datetime-local" value={started} onChange={(e) => setStarted(e.target.value)} />
        </label>
        <label className="form-field full">
          <span>工作描述</span>
          <textarea rows={2} value={comment} onChange={(e) => setComment(e.target.value)} />
        </label>
      </div>
      <p className="muted small">时间单位：w 周、d 天、h 小时、m 分钟。剩余估算会自动扣减。</p>
      {error && <ErrorBox message={error} />}
      <div className="composer-actions">
        <button className="btn" onClick={onCancel}>
          取消
        </button>
        <button className="btn primary" disabled={!timeSpent.trim() || !started || saving} onClick={save}>
          {saving ? "保存中…" : worklog ? "保存修改" : "记录"}
        </button>
      </div>
    </div>
  );
}

// ---------- 流转记录 ----------

/** 时长显示为“3天 4小时 5分”；不足一分钟显示秒。 */
function formatSpan(ms: number): string {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s}秒`;
  const [d, h, m] = [Math.floor(s / 86400), Math.floor((s % 86400) / 3600), Math.floor((s % 3600) / 60)];
  return [d && `${d}天`, h && `${h}小时`, m && `${m}分`].filter(Boolean).join(" ") || "0分";
}

/** 状态流转记录：每次流转、执行人，以及在原状态停留的时间；下面汇总每个状态累计停留的时间。 */
function StatusFlow({ issue }: { issue: IssueDetail }) {
  const [entries, setEntries] = useState<HistoryEntry[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const load = useCallback(async () => {
    setError(null);
    try {
      setEntries(await api.jiraHistory(issue.key));
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [issue.key]);
  useEffect(() => {
    void load();
  }, [load]);
  if (error) return <ErrorBox message={error} onRetry={load} />;
  if (!entries) return <Skeleton lines={4} />;

  const steps = entries.flatMap((h) => h.items.filter((i) => i.fieldId === "status").map((i) => ({ id: h.id, author: h.author, at: h.created, from: i.from ?? "", to: i.to ?? "" })));
  if (steps.length === 0) return <p className="muted small">还没有状态流转，一直处于「{issue.status.name}」，已 {formatSpan(Date.now() - parseTime(issue.created).getTime())}。</p>;
  const rows = steps.map((s, i) => ({ ...s, stay: parseTime(s.at).getTime() - parseTime(i === 0 ? issue.created : steps[i - 1].at).getTime() }));
  // 各状态累计停留时间（含当前状态到现在）
  const totals = new Map<string, number>();
  rows.forEach((r) => totals.set(r.from, (totals.get(r.from) ?? 0) + r.stay));
  const current = Date.now() - parseTime(steps[steps.length - 1].at).getTime();
  totals.set(issue.status.name, (totals.get(issue.status.name) ?? 0) + current);
  return (
    <>
      <table className="flow-table">
        <thead>
          <tr>
            <th>流转</th>
            <th>在原状态停留</th>
            <th>执行人</th>
            <th>时间</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((r, i) => (
            <tr key={`${r.id}-${i}`}>
              <td>
                {r.from} <ArrowRight size={12} className="muted" /> {r.to}
              </td>
              <td className="nowrap">{formatSpan(r.stay)}</td>
              <td className="nowrap">{r.author}</td>
              <td className="nowrap muted">{formatTime(r.at)}</td>
            </tr>
          ))}
          <tr className="muted">
            <td>当前：{issue.status.name}</td>
            <td className="nowrap">{formatSpan(current)}</td>
            <td />
            <td />
          </tr>
        </tbody>
      </table>
      <div className="flow-totals small">
        {[...totals.entries()]
          .sort((a, b) => b[1] - a[1])
          .map(([status, ms]) => (
            <span key={status} className="extra-chip">
              <span className="muted">{status}</span>
              {formatSpan(ms)}
            </span>
          ))}
      </div>
    </>
  );
}

// ---------- 变更历史 ----------

function HistoryList({ issueKey, created, reporter }: { issueKey: string; created: string; reporter: string | null }) {
  const [entries, setEntries] = useState<HistoryEntry[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  const load = useCallback(async () => {
    setError(null);
    try {
      // 最近的变更排在前面
      setEntries((await api.jiraHistory(issueKey)).reverse());
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [issueKey]);

  useEffect(() => {
    void load();
  }, [load]);

  if (error) return <ErrorBox message={error} onRetry={load} />;
  if (!entries) return <Skeleton lines={4} />;
  return (
    <ol className="history">
      {entries.map((h) => (
        <li key={h.id} className="comment">
          <Avatar name={h.author} size={24} />
          <div className="history-card">
            <div className="comment-meta">
              <strong>{h.author}</strong>
              <span className="muted small">{formatTime(h.created)}</span>
            </div>
            {h.items.map((item, i) => (
              <div className="history-item" key={i}>
                <span className="field-name">{item.field}</span>
                <span className="history-change">
                  {item.from ? <del className="clamp">{item.from}</del> : <span className="muted">无</span>}
                  <ArrowRight size={12} className="muted" />
                  {item.to ? <span className="clamp">{item.to}</span> : <span className="muted">无</span>}
                </span>
              </div>
            ))}
          </div>
        </li>
      ))}
      {/* 与网页一致，最后一条是创建问题 */}
      <li className="comment">
        <Avatar name={reporter ?? "?"} size={24} />
        <div className="history-card">
          <div className="comment-meta">
            <strong>{reporter ?? "未知"}</strong>
            <span className="muted small">创建了问题 · {formatTime(created)}</span>
          </div>
        </div>
      </li>
    </ol>
  );
}
