import { useCallback, useEffect, useMemo, useState, type ReactNode } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import {
  ArrowLeft, Check, CheckCircle2, CircleAlert, CircleDot, Copy, ExternalLink, FileDiff as FileDiffIcon, GitCommitHorizontal, GitMerge,
  GitPullRequestClosed, LoaderCircle, MessageSquare, MoreHorizontal, Pencil, RefreshCw, Reply, ThumbsUp, Trash2, Undo2,
} from "lucide-react";
import { api, errorMessage, type Approvals, type Branch, type Commit, type Discussion, type FileDiff, type GlProjectRef, type GlUser, type MergeRequest, type MrNote } from "../../api";
import { Avatar, ErrorBox, Modal, Skeleton, Spinner } from "../../components/common";
import { CommentBox } from "../../components/CommentBox";
import { useContextMenu, type MenuInput } from "../../components/ContextMenu";
import { contributeMenu } from "../../components/MenuHost";
import { RichHtml } from "../../components/RichHtml";
import { toast } from "../../components/Toast";
import { copyText } from "../../lib/clipboard";
import { formatTime } from "../../lib/format";
import { gitlabMarkdown } from "../../lib/gitlabMarkdown";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { DiffList, lineKeyOf, type DiffAnnotations } from "./DiffView";
import { mrMenu } from "./gitlabMenu";
import { CommitDetailView, CommitList } from "./ProjectView";
import { PIPELINE_LABELS, STATE_LABELS } from "./labels";
import { RelatedIssues } from "./RelatedIssues";

export interface MrRef {
  project: GlProjectRef;
  iid: number;
}

type Tab = "overview" | "commits" | "changes";

let mePromise: Promise<GlUser> | null = null;
/** 当前 GitLab 用户（用于判断哪些评论可以编辑、删除）。 */
export function glMe(): Promise<GlUser> {
  mePromise ??= api.glMe().catch((e) => {
    mePromise = null;
    throw e;
  });
  return mePromise;
}

/** 合并请求的项目路径（从完整引用 group/project!12 中取）。 */
export function mrProjectPath(mr: MergeRequest): string {
  return mr.reference.split("!")[0];
}

/** 项目网页地址：去掉合并请求地址的 /-/merge_requests/12 部分。 */
function projectUrlOf(mr: MergeRequest): string {
  return mr.webUrl.replace(/\/-\/merge_requests\/\d+$/, "");
}

const DRAFT_PREFIX = /^\s*(\[draft\]|\(draft\)|draft:|draft\s|\[wip\]|wip:)\s*/i;


export function MrStatePill({ mr }: { mr: MergeRequest }) {
  const cls = mr.state === "merged" ? "status-done" : mr.state === "opened" ? "status-indeterminate" : "status-new";
  return <span className={`status ${cls}`}>{STATE_LABELS[mr.state] ?? mr.state}</span>;
}


/** GitLab 系统记录的常见英文文案。 */
function systemText(body: string): string {
  const rules: [RegExp, string][] = [
    [/^approved this merge request$/, "批准了此合并请求"],
    [/^unapproved this merge request$/, "取消了批准"],
    [/^marked this merge request as \*\*draft\*\*$/, "标记为草稿"],
    [/^marked this merge request as \*\*ready\*\*$/, "标记为就绪"],
    [/^changed the description$/, "修改了描述"],
    [/^changed title from (.*)$/s, "修改了标题：$1"],
    [/^closed$/, "关闭了此合并请求"],
    [/^reopened$/, "重新打开了此合并请求"],
    [/^merged$/, "合并了此合并请求"],
    [/^mentioned in commit (\w+)$/, "在提交 $1 中提及"],
    [/^mentioned in merge request (.*)$/, "在合并请求 $1 中提及"],
    [/^resolved all threads$/, "解决了所有讨论"],
    [/^added (\d+) commits?/, "推送了 $1 个提交"],
    [/^changed target branch from (.*) to (.*)$/, "目标分支从 $1 改为 $2"],
    [/^requested review from (.*)$/, "请 $1 审核"],
    [/^assigned to (.*)$/, "指派给 $1"],
    [/^enabled an automatic merge when the pipeline for (\w+) succeeds$/, "设置了流水线通过后自动合并"],
  ];
  const first = body.trim().split("\n")[0];
  for (const [re, text] of rules) if (re.test(first)) return first.replace(re, text);
  return first;
}

export function MergeRequestView({ mrRef, onBack, onChanged }: { mrRef: MrRef; onBack?: () => void; onChanged?: (mr: MergeRequest) => void }) {
  const { navigate } = useNav();
  const { isReady } = useSettings();
  const [mr, setMr] = useState<MergeRequest | null>(null);
  const [approvals, setApprovals] = useState<Approvals | null>(null);
  const [discussions, setDiscussions] = useState<Discussion[] | null>(null);
  const [me, setMe] = useState<GlUser | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [tab, setTab] = useState<Tab>("overview");
  const [commits, setCommits] = useState<Commit[] | null>(null);
  const [changes, setChanges] = useState<{ diffs: FileDiff[]; overflow: boolean } | null>(null);
  const [subError, setSubError] = useState<string | null>(null);
  const [merging, setMerging] = useState(false);
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState(false);
  const moreMenu = useContextMenu();

  const project = mr?.projectId ?? mrRef.project;
  const iid = mrRef.iid;

  const load = useCallback(async () => {
    setError(null);
    try {
      const [m, d] = await Promise.all([api.glMergeRequest(mrRef.project, iid), api.glMrDiscussions(mrRef.project, iid)]);
      setMr(m);
      setDiscussions(d);
      api.glMrApprovals(m.projectId, iid).then(setApprovals, () => setApprovals(null));
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [mrRef.project, iid]);

  useEffect(() => {
    void load();
    glMe().then(setMe, () => {});
  }, [load]);

  // 提交和改动在切换到对应标签时再加载
  useEffect(() => {
    if (!mr) return;
    setSubError(null);
    if (tab === "commits" && !commits) api.glMrCommits(mr.projectId, iid).then(setCommits, (e) => setSubError(errorMessage(e)));
    if (tab === "changes" && !changes) api.glMrChanges(mr.projectId, iid).then(setChanges, (e) => setSubError(errorMessage(e)));
  }, [tab, mr, iid, commits, changes]);

  const updated = (next: MergeRequest) => {
    setMr(next);
    onChanged?.(next);
  };

  // ---------- 讨论 ----------
  const replaceDiscussion = (d: Discussion) => setDiscussions((list) => (list ?? []).map((x) => (x.id === d.id ? d : x)));
  const threadActions: ThreadActions = {
    me,
    projectUrl: mr ? projectUrlOf(mr) : "",
    reply: async (d, body) => {
      const note = await api.glMrReply(project, iid, d.id, body);
      replaceDiscussion({ ...d, notes: [...d.notes, note] });
    },
    resolve: async (d, resolved) => replaceDiscussion(await api.glMrResolve(project, iid, d.id, resolved)),
    edit: async (d, note, body) => {
      const next = await api.glMrEditNote(project, iid, note.id, body);
      replaceDiscussion({ ...d, notes: d.notes.map((n) => (n.id === note.id ? next : n)) });
    },
    remove: async (d, note) => {
      if (!window.confirm("确定删除这条评论吗？")) return;
      await api.glMrDeleteNote(project, iid, note.id);
      const notes = d.notes.filter((n) => n.id !== note.id);
      setDiscussions((list) => (notes.length === 0 ? (list ?? []).filter((x) => x.id !== d.id) : (list ?? []).map((x) => (x.id === d.id ? { ...d, notes } : x))));
    },
  };

  /** 在当前版本改动上的行内讨论；基于旧版本的只在概览中显示。 */
  const annotations = useMemo<DiffAnnotations | undefined>(() => {
    if (!mr || !discussions) return undefined;
    const threads = new Map<string, ReactNode>();
    for (const d of discussions) {
      const pos = d.notes[0]?.position;
      if (!pos || pos.headSha !== mr.diffRefs?.headSha) continue;
      const key = lineKeyOf(pos.newPath, pos);
      threads.set(key, (
        <>
          {threads.get(key)}
          <Thread discussion={d} actions={threadActions} compact />
        </>
      ));
    }
    const refs = mr.diffRefs;
    return {
      threads,
      onComment:
        refs && mr.state === "opened"
          ? async (diff, line, body) => {
              const d = await api.glMrAddNote(project, iid, body, { ...refs, oldPath: diff.oldPath, newPath: diff.newPath, oldLine: line.oldLine, newLine: line.newLine });
              setDiscussions((list) => [...(list ?? []), d]);
            }
          : undefined,
    };
    // threadActions 每次渲染都会重建，只取决于讨论和当前用户
  }, [mr, discussions, me]);

  if (error)
    return (
      <div className="detail-body">
        {onBack && <BackButton onBack={onBack} />}
        <ErrorBox message={error} onRetry={load} />
      </div>
    );
  if (!mr)
    return (
      <div className="detail-body">
        <Skeleton lines={2} height={22} />
        <Skeleton lines={10} />
      </div>
    );

  const projectPath = mrProjectPath(mr);
  const unresolved = (discussions ?? []).filter((d) => d.notes.some((n) => n.resolvable && !n.resolved)).length;
  const copy = (text: string, label = "已复制") => () =>
    copyText(text).then(
      () => toast(label),
      (e) => toast(`复制失败：${errorMessage(e)}`, true),
    );

  const run = async (action: () => Promise<void>) => {
    setBusy(true);
    try {
      await action();
    } catch (e) {
      toast(errorMessage(e), true);
    } finally {
      setBusy(false);
    }
  };

  const toggleDraft = () =>
    run(async () => {
      const title = mr.draft ? mr.title.replace(DRAFT_PREFIX, "") : `Draft: ${mr.title}`;
      updated(await api.glMrUpdate(project, iid, { title }));
      toast(mr.draft ? "已标记为就绪" : "已标记为草稿");
    });

  const setState = (event: "close" | "reopen") =>
    run(async () => {
      if (event === "close" && !window.confirm(`确定关闭合并请求 !${mr.iid} 吗？`)) return;
      updated(await api.glMrUpdate(project, iid, { stateEvent: event }));
      toast(event === "close" ? "已关闭" : "已重新打开");
    });

  const approve = (yes: boolean) =>
    run(async () => {
      setApprovals(await api.glMrApprove(project, iid, yes));
      toast(yes ? "已批准" : "已取消批准");
    });

  const refresh = () => {
    setCommits(null);
    setChanges(null);
    void load();
  };

  // 更多按钮、详情空白处右键共用
  const moreEntries: MenuInput[] = [
    mr.state === "opened" && { label: "编辑标题和描述", icon: <Pencil size={14} />, onSelect: () => setEditing(true) },
    mr.state === "opened" && { label: mr.draft ? "标记为就绪" : "标记为草稿", onSelect: toggleDraft },
    { label: "刷新", icon: <RefreshCw size={14} />, onSelect: refresh },
    "separator",
    ...mrMenu(mr, navigate, { jira: isReady("jira") }),
    mr.state === "opened" && "separator",
    mr.state === "opened" && { label: "关闭合并请求", icon: <GitPullRequestClosed size={14} />, danger: true, onSelect: () => setState("close") },
  ];

  return (
    <div className="detail-body" onContextMenu={(e) => contributeMenu(e, { label: `!${mr.iid}`, items: moreEntries })}>
      <header className="issue-header">
        <div className="issue-header-top">
          {onBack && <BackButton onBack={onBack} />}
          <button className="link" onClick={() => navigate({ page: "gitlab", projectId: mr.projectId })} title="打开项目">
            {projectPath}
          </button>
          <span>!{mr.iid}</span>
          <span className="spacer" />
          <button className="btn subtle icon" title="刷新" onClick={refresh}>
            <RefreshCw size={14} />
          </button>
          <button className="btn subtle icon" title="在浏览器中打开" onClick={() => openUrl(mr.webUrl)}>
            <ExternalLink size={14} />
          </button>
        </div>
        <h1>
          {mr.draft && <span className="tag mr-draft-tag">草稿</span>}
          {mr.title}
        </h1>
        <div className="mr-meta muted small">
          <MrStatePill mr={mr} />
          <Avatar name={mr.author.name} size={18} />
          <span>
            {mr.author.name} 创建于 {formatTime(mr.createdAt)}
          </span>
          <span className="mr-branches">
            <code title="源分支">{mr.sourceBranch}</code>
            <span>→</span>
            <code title="目标分支">{mr.targetBranch}</code>
            <button className="btn subtle icon small-icon" title="复制源分支名" onClick={copy(mr.sourceBranch, "已复制分支名")}>
              <Copy size={12} />
            </button>
          </span>
        </div>
        <div className="issue-actions">
          <div className="segmented">
            {(
              [
                ["overview", `概览${discussions && discussions.some((d) => !d.notes[0]?.system) ? ` ${discussions.filter((d) => !d.notes[0]?.system).length}` : ""}`, MessageSquare],
                ["commits", `提交${commits ? ` ${commits.length}` : ""}`, GitCommitHorizontal],
                ["changes", `改动${mr.changesCount ? ` ${mr.changesCount}` : ""}`, FileDiffIcon],
              ] as const
            ).map(([id, label, Icon]) => (
              <button key={id} className={tab === id ? "active" : ""} onClick={() => setTab(id)}>
                <Icon size={14} />
                {label}
              </button>
            ))}
          </div>
          <span className="spacer" />
          {mr.state === "opened" && approvals?.userCanApprove && !approvals.userHasApproved && (
            <button className="btn" disabled={busy} onClick={() => approve(true)}>
              <ThumbsUp size={14} />
              批准
            </button>
          )}
          {mr.state === "opened" && approvals?.userHasApproved && (
            <button className="btn" disabled={busy} onClick={() => approve(false)}>
              <Undo2 size={14} />
              取消批准
            </button>
          )}
          {mr.state === "opened" && mr.canMerge && (
            <button className="btn primary" disabled={busy || !mergeable(mr)} title={mergeable(mr) ? "" : mergeBlocker(mr)} onClick={() => setMerging(true)}>
              <GitMerge size={14} />
              合并
            </button>
          )}
          {mr.state === "closed" && (
            <button className="btn" disabled={busy} onClick={() => setState("reopen")}>
              重新打开
            </button>
          )}
          <button className={`btn subtle icon${moreMenu.target === "more" ? " active" : ""}`} title="更多" onClick={(e) => moreMenu.open(e, moreEntries, "more")}>
            <MoreHorizontal size={16} />
          </button>
        </div>
      </header>

      {tab === "overview" && (
        <>
          <StatusPanel mr={mr} approvals={approvals} unresolved={unresolved} />
          <RelatedIssues target={{ projectPath, iid: mr.iid, text: `${mr.title} ${mr.sourceBranch} ${mr.description}` }} />
          <section className="block">
            {mr.description.trim() ? (
              <RichHtml service="gitlab" className="rich mr-description" html={gitlabMarkdown(mr.description, projectUrlOf(mr))} />
            ) : (
              <p className="muted small">没有描述</p>
            )}
          </section>
          <section className="block">
            <h2>
              <MessageSquare size={16} className="muted" />
              动态
            </h2>
            {!discussions && <Skeleton lines={3} />}
            {discussions && (
              <ul className="mr-timeline">
                {[...discussions]
                  .sort((a, b) => (a.notes[0]?.createdAt ?? "").localeCompare(b.notes[0]?.createdAt ?? ""))
                  .map((d) =>
                    d.notes.every((n) => n.system) ? (
                      d.notes.map((n) => (
                        <li key={n.id} className="mr-system-note muted small">
                          <CircleDot size={12} />
                          <strong>{n.author.name}</strong>
                          <span className="ellipsis">{systemText(n.body)}</span>
                          <span className="mr-note-time">{formatTime(n.createdAt)}</span>
                        </li>
                      ))
                    ) : (
                      <li key={d.id}>
                        <Thread
                          discussion={d}
                          actions={threadActions}
                          outdated={!!d.notes[0]?.position && d.notes[0].position.headSha !== mr.diffRefs?.headSha}
                          onShowDiff={() => setTab("changes")}
                        />
                      </li>
                    ),
                  )}
              </ul>
            )}
            <CommentBox
              placeholder="发表评论，支持 Markdown（⌘↵ 发送）"
              onSubmit={async (body) => {
                const d = await api.glMrAddNote(project, iid, body);
                setDiscussions((list) => [...(list ?? []), d]);
              }}
            />
          </section>
        </>
      )}

      {tab === "commits" && <CommitsPane projectId={mr.projectId} projectPath={projectPath} commits={commits} error={subError} />}

      {tab === "changes" && (
        <section className="block">
          {subError && <ErrorBox message={subError} />}
          {!changes && !subError && <Spinner />}
          {changes?.overflow && <p className="muted small">改动过多，只显示了部分文件。</p>}
          {changes && (changes.diffs.length === 0 ? <p className="muted">没有改动。</p> : <DiffList diffs={changes.diffs} annotations={annotations} />)}
          {annotations?.onComment && changes && changes.diffs.length > 0 && <p className="muted small">鼠标移到行号上，点击出现的按钮即可评论这一行。</p>}
        </section>
      )}

      {merging && (
        <MergeDialog
          mr={mr}
          approvals={approvals}
          unresolved={unresolved}
          onClose={() => setMerging(false)}
          onMerged={(next) => {
            setMerging(false);
            updated(next);
            void load();
            toast(`已合并到 ${next.targetBranch}`);
          }}
        />
      )}
      {editing && (
        <EditDialog
          mr={mr}
          onClose={() => setEditing(false)}
          onSaved={(next) => {
            setEditing(false);
            updated(next);
            setChanges(null);
            setCommits(null);
            toast("已保存");
          }}
        />
      )}
      {moreMenu.menu}
    </div>
  );
}

function BackButton({ onBack }: { onBack: () => void }) {
  return (
    <button className="btn subtle" onClick={onBack}>
      <ArrowLeft size={14} />
      返回
    </button>
  );
}

/** GitLab 只在需要时才重新检查能否合并，“未检查”时网页端也允许合并（合并时再检查），这里保持一致。 */
function mergeable(mr: MergeRequest): boolean {
  return mr.canMerge && !mr.draft && !mr.hasConflicts && mr.mergeStatus !== "cannot_be_merged";
}

function mergeBlocker(mr: MergeRequest): string {
  if (mr.draft) return "草稿状态不能合并，先标记为就绪";
  if (mr.hasConflicts || mr.mergeStatus === "cannot_be_merged") return "有冲突，需要先解决";
  return "";
}

function StatusPanel({ mr, approvals, unresolved }: { mr: MergeRequest; approvals: Approvals | null; unresolved: number }) {
  const rows: { ok: boolean | null; text: string }[] = [];
  if (mr.state === "merged") {
    rows.push({ ok: true, text: `${mr.mergedBy?.name ?? ""} 于 ${formatTime(mr.mergedAt)} 合并到 ${mr.targetBranch}` });
  } else if (mr.state === "closed") {
    rows.push({ ok: null, text: `${mr.closedBy?.name ?? ""} 于 ${formatTime(mr.closedAt)} 关闭` });
  } else {
    if (mr.hasConflicts) rows.push({ ok: false, text: "有冲突，需要在本地合并目标分支后重新推送" });
    else if (mr.mergeStatus === "can_be_merged") rows.push({ ok: true, text: mr.draft ? "没有冲突（草稿状态，标记为就绪后才能合并）" : "没有冲突，可以合并" });
    else if (mr.mergeStatus === "cannot_be_merged") rows.push({ ok: false, text: "无法自动合并，需要在本地合并目标分支后重新推送" });
    else rows.push({ ok: null, text: "GitLab 尚未检查是否有冲突，合并时会再检查" });
    if (mr.mergeError) rows.push({ ok: false, text: `上次合并失败：${mr.mergeError}` });
  }
  if (mr.headPipeline) {
    const s = mr.headPipeline.status;
    rows.push({ ok: s === "success" ? true : s === "failed" ? false : null, text: PIPELINE_LABELS[s] ?? `流水线：${s}` });
  }
  if (approvals) {
    rows.push(
      approvals.approvedBy.length > 0
        ? { ok: true, text: `已由 ${approvals.approvedBy.map((u) => u.name).join("、")} 批准` }
        : { ok: null, text: "尚未有人批准" },
    );
  }
  if (unresolved > 0) rows.push({ ok: false, text: `${unresolved} 个讨论未解决` });
  return (
    <ul className="mr-status">
      {rows.map((r, i) => (
        <li key={i} className={r.ok === true ? "ok" : r.ok === false ? "bad" : ""}>
          {r.ok === true ? <CheckCircle2 size={15} /> : r.ok === false ? <CircleAlert size={15} /> : <LoaderCircle size={15} />}
          {r.text}
        </li>
      ))}
    </ul>
  );
}

function CommitsPane({ projectId, projectPath, commits, error }: { projectId: number; projectPath: string; commits: Commit[] | null; error: string | null }) {
  const [selected, setSelected] = useState<string | null>(null);
  if (selected) return <CommitDetailView projectId={projectId} projectPath={projectPath} sha={selected} onBack={() => setSelected(null)} />;
  return (
    <section className="block">
      {error && <ErrorBox message={error} />}
      {!commits && !error && <Spinner />}
      {commits && <CommitList commits={commits} onOpen={setSelected} />}
    </section>
  );
}

// ---------- 讨论 ----------

interface ThreadActions {
  me: GlUser | null;
  projectUrl: string;
  reply: (d: Discussion, body: string) => Promise<void>;
  resolve: (d: Discussion, resolved: boolean) => Promise<void>;
  edit: (d: Discussion, note: MrNote, body: string) => Promise<void>;
  remove: (d: Discussion, note: MrNote) => Promise<void>;
}

/** 一个讨论串。`compact` 用在改动中的行下面（不显示文件位置）。 */
function Thread({ discussion: d, actions, compact, outdated, onShowDiff }: { discussion: Discussion; actions: ThreadActions; compact?: boolean; outdated?: boolean; onShowDiff?: () => void }) {
  const [replying, setReplying] = useState(false);
  const [editing, setEditing] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const notes = d.notes.filter((n) => !n.system);
  const first = notes[0];
  const resolvable = d.notes.some((n) => n.resolvable);
  const resolved = resolvable && d.notes.every((n) => !n.resolvable || n.resolved);
  const [collapsed, setCollapsed] = useState(resolved);
  const pos = first?.position;

  const resolve = async () => {
    setBusy(true);
    try {
      await actions.resolve(d, !resolved);
      setCollapsed(!resolved);
    } catch (e) {
      toast(errorMessage(e), true);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className={`mr-thread${resolved ? " resolved" : ""}`}>
      {(!compact && pos) || resolvable ? (
        <div className="mr-thread-head muted small">
          {!compact && pos && (
            <>
              <FileDiffIcon size={13} />
              <button className="link ellipsis" onClick={onShowDiff} title="查看改动">
                {pos.newPath}:{pos.newLine ?? pos.oldLine}
              </button>
              {outdated && <span className="tag muted-tag">旧版本</span>}
            </>
          )}
          <span className="spacer" />
          {resolved && (
            <button className="link" onClick={() => setCollapsed((v) => !v)}>
              {collapsed ? `已解决 · 展开 ${notes.length} 条` : "收起"}
            </button>
          )}
          {resolvable && (
            <button className="btn subtle small-btn" disabled={busy} onClick={resolve}>
              <Check size={13} />
              {resolved ? "重新打开" : "解决"}
            </button>
          )}
        </div>
      ) : null}
      {!collapsed &&
        notes.map((n) => (
          <div
            key={n.id}
            className="mr-note"
            onContextMenu={(e) =>
              editing !== n.id &&
              contributeMenu(e, {
                label: "评论",
                items: [
                  (!d.individualNote || resolvable) && { label: "回复", icon: <Reply size={14} />, onSelect: () => setReplying(true) },
                  resolvable && { label: resolved ? "重新打开讨论" : "解决讨论", icon: <Check size={14} />, onSelect: resolve },
                  actions.me?.id === n.author.id && { label: "编辑", icon: <Pencil size={14} />, onSelect: () => setEditing(n.id) },
                  "separator",
                  {
                    label: "复制评论内容",
                    icon: <Copy size={14} />,
                    onSelect: () =>
                      copyText(n.body).then(
                        () => toast("已复制"),
                        (err) => toast(`复制失败：${errorMessage(err)}`, true),
                      ),
                  },
                  actions.me?.id === n.author.id && "separator",
                  actions.me?.id === n.author.id && { label: "删除", icon: <Trash2 size={14} />, danger: true, onSelect: () => actions.remove(d, n).catch((err) => toast(errorMessage(err), true)) },
                ],
              })
            }
          >
            <div className="wiki-comment-head">
              <Avatar name={n.author.name} size={22} />
              <strong>{n.author.name}</strong>
              <span className="muted small">{formatTime(n.createdAt)}</span>
              <span className="spacer" />
              {actions.me?.id === n.author.id && editing !== n.id && (
                <>
                  <button className="btn subtle icon small-icon" title="编辑" onClick={() => setEditing(n.id)}>
                    <Pencil size={13} />
                  </button>
                  <button className="btn subtle icon small-icon" title="删除" onClick={() => actions.remove(d, n).catch((e) => toast(errorMessage(e), true))}>
                    <Trash2 size={13} />
                  </button>
                </>
              )}
            </div>
            {editing === n.id ? (
              <CommentBox
                initial={n.body}
                submitLabel="保存"
                placeholder="编辑评论（⌘↵ 保存，Esc 取消）"
                onCancel={() => setEditing(null)}
                onSubmit={async (body) => {
                  await actions.edit(d, n, body);
                  setEditing(null);
                }}
              />
            ) : (
              <RichHtml service="gitlab" className="rich" html={gitlabMarkdown(n.body, actions.projectUrl)} />
            )}
          </div>
        ))}
      {!collapsed &&
        (replying ? (
          <CommentBox
            placeholder="回复（⌘↵ 发送，Esc 取消）"
            onCancel={() => setReplying(false)}
            onSubmit={async (body) => {
              await actions.reply(d, body);
              setReplying(false);
            }}
          />
        ) : (
          !d.individualNote || resolvable ? (
            <button className="btn subtle small-btn mr-reply" onClick={() => setReplying(true)}>
              <Reply size={13} />
              回复
            </button>
          ) : null
        ))}
    </div>
  );
}

// ---------- 对话框 ----------

function MergeDialog({ mr, approvals, unresolved, onClose, onMerged }: { mr: MergeRequest; approvals: Approvals | null; unresolved: number; onClose: () => void; onMerged: (mr: MergeRequest) => void }) {
  const [squash, setSquash] = useState(mr.squash);
  const [removeSource, setRemoveSource] = useState(mr.forceRemoveSourceBranch ?? false);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const submit = async () => {
    setSubmitting(true);
    setError(null);
    try {
      onMerged(await api.glMrMerge(mr.projectId, mr.iid, { squash, removeSourceBranch: removeSource, sha: mr.sha }));
    } catch (e) {
      setError(errorMessage(e));
      setSubmitting(false);
    }
  };

  return (
    <Modal
      title={`合并 !${mr.iid}`}
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            取消
          </button>
          <button className="btn primary" disabled={submitting} onClick={submit}>
            <GitMerge size={14} />
            {submitting ? "合并中…" : "合并"}
          </button>
        </>
      }
    >
      <p>
        把 <code>{mr.sourceBranch}</code> 合并到 <code>{mr.targetBranch}</code>。
      </p>
      {approvals && approvals.approvedBy.length === 0 && <p className="muted small">提示：还没有人批准。</p>}
      {unresolved > 0 && <p className="muted small">提示：还有 {unresolved} 个讨论未解决。</p>}
      {mr.headPipeline && mr.headPipeline.status !== "success" && <p className="muted small">提示：{PIPELINE_LABELS[mr.headPipeline.status] ?? mr.headPipeline.status}。</p>}
      <label className="checkbox">
        <input type="checkbox" checked={removeSource} onChange={(e) => setRemoveSource(e.target.checked)} />
        合并后删除源分支
      </label>
      <label className="checkbox">
        <input type="checkbox" checked={squash} onChange={(e) => setSquash(e.target.checked)} />
        压缩为一个提交（squash）
      </label>
      <p className="muted small">只在合并请求仍是当前看到的版本时合并；如果期间有人推送了新提交，会提示失败，刷新后再看。</p>
      {mr.mergeStatus !== "can_be_merged" && <p className="muted small">GitLab 还没检查是否有冲突，合并时会检查；有冲突会提示失败。</p>}
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}

function EditDialog({ mr, onClose, onSaved }: { mr: MergeRequest; onClose: () => void; onSaved: (mr: MergeRequest) => void }) {
  const [title, setTitle] = useState(mr.title);
  const [description, setDescription] = useState(mr.description);
  const [target, setTarget] = useState(mr.targetBranch);
  const [branches, setBranches] = useState<Branch[] | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.glBranches(mr.projectId).then(setBranches, () => setBranches([]));
  }, [mr.projectId]);

  const dirty = title !== mr.title || description !== mr.description || target !== mr.targetBranch;
  const submit = async () => {
    setSubmitting(true);
    setError(null);
    try {
      onSaved(
        await api.glMrUpdate(mr.projectId, mr.iid, {
          title: title !== mr.title ? title : undefined,
          description: description !== mr.description ? description : undefined,
          targetBranch: target !== mr.targetBranch ? target : undefined,
        }),
      );
    } catch (e) {
      setError(errorMessage(e));
      setSubmitting(false);
    }
  };

  return (
    <Modal
      title={`编辑 !${mr.iid}`}
      wide
      dirty={dirty}
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            取消
          </button>
          <button className="btn primary" disabled={!dirty || !title.trim() || submitting} onClick={submit}>
            {submitting ? "保存中…" : "保存"}
          </button>
        </>
      }
    >
      <label className="form-field">
        <span>标题</span>
        <input value={title} onChange={(e) => setTitle(e.target.value)} />
      </label>
      <label className="form-field">
        <span>目标分支</span>
        <select value={target} onChange={(e) => setTarget(e.target.value)}>
          {!branches?.some((b) => b.name === target) && <option value={target}>{target}</option>}
          {(branches ?? []).filter((b) => b.name !== mr.sourceBranch).map((b) => (
            <option key={b.name} value={b.name}>
              {b.name}
            </option>
          ))}
        </select>
      </label>
      <label className="form-field">
        <span>描述（Markdown）</span>
        <textarea rows={10} value={description} onChange={(e) => setDescription(e.target.value)} />
      </label>
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}
