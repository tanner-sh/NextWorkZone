import { useCallback, useEffect, useRef, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { api, errorMessage, type Attachment, type HistoryEntry, type IssueDetail, type IssueHit, type IssueSummary, type SimilarIssues, type TimeTracking, type Transition, type Watchers, type WikiPageHit } from "../../api";
import { RichHtml } from "../../components/RichHtml";
import { useDropTarget } from "../../components/FileDropLayer";
import { BookOpen, BookText, CheckSquare, ChevronDown, ChevronRight, Eye, ExternalLink, FileText, History, NotepadText, Paperclip, Pencil, Plus, RefreshCw, Sparkles, Upload, X, Zap } from "lucide-react";
import { useContextMenu, type MenuInput } from "../../components/ContextMenu";
import { contributeMenu, useMenus } from "../../components/MenuHost";
import { guarded, toast } from "../../components/Toast";
import { AssignDialog } from "./issueMenu";
import { AttachmentViewer, attachmentMenu as attachmentItems } from "../../components/AttachmentViewer";
import { Avatar, ErrorBox, Skeleton, StatusPill, SysImg, WebLoginHint } from "../../components/common";
import { assetUrl } from "../../lib/asset";
import { formatSize, formatTime, parseTime } from "../../lib/format";
import { reminderLabel, useReminders } from "../../lib/reminders";
import { useTemplates, type JiraTemplate } from "../../lib/templates";
import { lastSeen, markViewed } from "../../lib/viewed";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { CreateIssueDialog } from "./CreateIssueDialog";
import { EditIssueDialog } from "./EditIssueDialog";
import { IssueActivity } from "./IssueActivity";
import { IssueCode } from "./IssueCode";
import { Links, Subtasks } from "./IssueRelations";
import { Backlinks } from "../workspace/Backlinks";
import { issueToPage } from "../workspace/kbImport";
import { addIssueTodo, createIssueNote } from "../workspace/issueActions";
import { projectKeyOf } from "./jql";
import { TransitionDialog } from "./TransitionDialog";

const COLLAPSED_FIELD_COUNT = 10;

export function IssueView({ issueKey, onChanged }: { issueKey: string; onChanged: (issue: IssueSummary) => void }) {
  const baseUrl = useSettings().baseUrl("jira");
  const [issue, setIssue] = useState<IssueDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [transitions, setTransitions] = useState<Transition[]>([]);
  const [activeTransition, setActiveTransition] = useState<{ transition: Transition; template?: JiraTemplate } | null>(null);
  /** 上次查看的时间（打开时问题在那之后有更新）及之后的变更记录 */
  const [changes, setChanges] = useState<{ since: number; history: HistoryEntry[] | null } | null>(null);
  const templates = useTemplates();
  const reminder = useReminders()?.items.find((r) => r.key === issueKey);
  const [showAllFields, setShowAllFields] = useState(false);
  const [editing, setEditing] = useState(false);
  const [creatingSubtask, setCreatingSubtask] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [me, setMe] = useState<string | null>(null);
  const [assigning, setAssigning] = useState(false);
  const priorityMenu = useContextMenu();
  const menus = useMenus();
  const { navigate } = useNav();
  /** 代码、Wiki、工作空间中的关联数，显示在标题下方 */
  const [related, setRelated] = useState<Record<RelatedKind, number>>({ code: 0, wiki: 0, workspace: 0 });
  const countCode = useCallback((n: number) => setRelated((r) => (r.code === n ? r : { ...r, code: n })), []);
  const countWiki = useCallback((n: number) => setRelated((r) => (r.wiki === n ? r : { ...r, wiki: n })), []);
  const countWorkspace = useCallback((n: number) => setRelated((r) => (r.workspace === n ? r : { ...r, workspace: n })), []);

  useEffect(() => {
    api.jiraMe().then(setMe, () => setMe(null));
  }, []);

  const load = useCallback(async () => {
    setError(null);
    try {
      const [detail, available] = await Promise.all([api.jiraIssue(issueKey), api.jiraTransitions(issueKey).catch(() => [])]);
      setIssue(detail);
      setTransitions(available);
      // 记录查看；上次查看之后有更新时找出具体变化
      const previous = await markViewed(detail).catch(() => null);
      const since = lastSeen(previous, detail);
      if (since && parseTime(detail.updated).getTime() > since) {
        setChanges({ since, history: null });
        api.jiraHistory(issueKey).then(
          (list) => setChanges({ since, history: list.filter((h) => parseTime(h.created).getTime() > since) }),
          () => setChanges({ since, history: [] }),
        );
      }
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [issueKey]);

  useEffect(() => {
    void load();
  }, [load]);

  const applyUpdate = (detail: IssueDetail) => {
    setIssue(detail);
    onChanged(detail);
    // 自己的修改不算新变化
    void markViewed(detail).catch(() => {});
    api.jiraTransitions(issueKey).then(setTransitions, () => setTransitions([]));
  };

  /** 工作日志变化后刷新耗费时间、剩余估算。 */
  const reloadIssue = () => {
    api.jiraIssue(issueKey).then(applyUpdate, () => {});
  };

  if (error) return <div className="detail-body"><ErrorBox message={error} onRetry={load} /></div>;
  if (!issue)
    return (
      <div className="detail-body">
        <Skeleton lines={2} height={22} />
        <Skeleton lines={6} />
      </div>
    );

  // 与网页一致只显示问题界面上的字段；“显示全部”时再加上界面外的隐藏字段
  const screenFields = issue.fields.filter((f) => !f.hidden);
  const hiddenCount = issue.fields.length - screenFields.length;
  const fields = showAllFields ? issue.fields : screenFields.slice(0, COLLAPSED_FIELD_COUNT);
  // 别人在上次查看之后修改的字段（按显示名称），在字段列表中高亮
  const othersChanges = (changes?.history ?? []).filter((h) => !me || h.authorName !== me);
  const changed = new Set(othersChanges.flatMap((h) => h.items.map((i) => i.field)));
  const rowClass = (...names: string[]) => `field-row${names.some((n) => changed.has(n)) ? " changed" : ""}`;
  const quickTemplates = templates.flatMap((tpl) => {
    const t = tpl.kind === "transition" && transitions.find((x) => x.name === tpl.transition);
    return t ? [{ tpl, t }] : [];
  });
  // 经办人单独显示在第一行（带分配操作）
  const inlineFields = fields.filter((f) => !f.html && f.id !== "assignee");
  const htmlFields = fields.filter((f) => f.html);

  // 问题详情空白处右键：编辑、新建子任务、刷新，以及与问题列表相同的问题菜单
  const issueActions: MenuInput[] = [
    { label: "编辑…", icon: <Pencil size={14} />, onSelect: () => setEditing(true) },
    !issue.parent && { label: "新建子任务…", icon: <Plus size={14} />, onSelect: () => setCreatingSubtask(true) },
    { label: "刷新", icon: <RefreshCw size={14} />, onSelect: reloadIssue },
    "separator",
    ...menus.issue(issue, { current: true, onUpdated: applyUpdate }),
  ];

  return (
    <div className="detail-body" onContextMenu={(e) => contributeMenu(e, { label: issue.key, items: issueActions })}>
      <header className="issue-header">
        <div className="issue-header-top">
          {issue.parent && (
            <>
              <SysImg service="jira" src={issue.parent.issueType?.iconUrl} className="icon16" />
              <button className="link ellipsis parent-link" onClick={() => navigate({ page: "jira", issueKey: issue.parent!.key })} onContextMenu={(e) => menus.open(e, menus.issue(issue.parent!))} title={issue.parent.summary}>
                {issue.parent.key} {issue.parent.summary}
              </button>
              <ChevronRight size={12} />
            </>
          )}
          <SysImg service="jira" src={issue.issueType.iconUrl} className="icon16" />
          <button className="link" onClick={() => openUrl(`${baseUrl}/browse/${issue.key}`)} title="在浏览器中打开">
            {issue.key}
          </button>
          <span>·</span>
          <span className="ellipsis">{issue.project.name}</span>
          <ExternalLink size={12} />
        </div>
        <h1>{issue.summary}</h1>
        <div className="issue-actions">
          <StatusPill status={issue.status} />
          {issue.resolution && <span className="muted small">解决结果：{issue.resolution}</span>}
          {reminder && !issue.resolution && <span className={`due-chip ${reminder.kind}`}>{reminderLabel(reminder.kind, reminder.days)}</span>}
          <span className="spacer" />
          {/* 流转放在前面：前两个直接显示（与 Jira 网页一致），其余和模板收进“更多” */}
          {transitions.slice(0, 2).map((t) => (
            <button key={t.id} className="btn" onClick={() => setActiveTransition({ transition: t })} title={`流转到「${t.to.name}」`}>
              {t.name}
            </button>
          ))}
          {transitions.length + quickTemplates.length > 2 && (
            <button
              className="btn"
              onClick={(e) =>
                menus.openAt(e.currentTarget, [
                  ...transitions.slice(2).map((t): MenuInput => ({ label: t.name, onSelect: () => setActiveTransition({ transition: t }) })),
                  quickTemplates.length > 0 && transitions.length > 2 && "separator",
                  ...quickTemplates.map(({ tpl, t }): MenuInput => ({ label: `${tpl.name}（${t.name}）`, icon: <Zap size={14} />, onSelect: () => setActiveTransition({ transition: t, template: tpl }) })),
                ])
              }
            >
              更多
              <ChevronDown size={14} />
            </button>
          )}
          {(transitions.length > 0 || quickTemplates.length > 0) && <span className="toolbar-divider" />}
          <button className="btn" onClick={() => setEditing(true)}>
            <Pencil size={14} />
            编辑
          </button>
          <WatchButton issueKey={issue.key} />
        </div>
        <RelatedSummary counts={related} />
      </header>

      {notice && (
        <div className="notice warn">
          <span className="grow">{notice}</span>
          <button className="btn" onClick={() => setNotice(null)}>
            知道了
          </button>
        </div>
      )}

      {changes && <ChangesSince since={changes.since} history={othersChanges} loading={changes.history === null} issue={issue} onDismiss={() => setChanges(null)} />}

      {(issue.attachments.length > 0 || issue.descriptionHtml?.includes("<img")) && <WebLoginHint service="jira" label="Jira" />}

      <section className="fields">
        <div className={rowClass("经办人", "Assignee", issue.fields.find((f) => f.id === "assignee")?.name ?? "")}>
          <span className="field-name">经办人</span>
          <span className="field-value">
            {issue.assignee ? (
              <>
                <Avatar name={issue.assignee} size={20} />
                <span className="ellipsis">{issue.assignee}</span>
              </>
            ) : (
              <span className="muted">未分配</span>
            )}
            {me && issue.assigneeName !== me && (
              <button className="btn subtle small-btn" onClick={guarded(async () => applyUpdate(await api.jiraAssign(issue.key, me)))}>
                分配给我
              </button>
            )}
            <button className="btn subtle small-btn" onClick={() => setAssigning(true)}>
              更改
            </button>
          </span>
        </div>
        <div className={rowClass("优先级", "Priority")}>
          <span className="field-name">优先级</span>
          <span className="field-value">
            <button
              className="btn subtle small-btn inline-select"
              title="修改优先级"
              onClick={async (e) => {
                const target = e.currentTarget;
                const list = await api.jiraPriorities().catch(() => []);
                priorityMenu.openAt(
                  target,
                  list.map((p) => ({
                    label: p.name,
                    checked: issue.priority?.name === p.name,
                    icon: <SysImg service="jira" src={p.iconUrl} className="icon16" />,
                    onSelect: issue.priority?.name === p.name ? undefined : guarded(async () => applyUpdate(await api.jiraSetPriority(issue.key, p.id))),
                  })),
                );
              }}
            >
              {issue.priority ? (
                <>
                  <SysImg service="jira" src={issue.priority.iconUrl} className="icon16" /> {issue.priority.name}
                </>
              ) : (
                <span className="muted">无</span>
              )}
              <ChevronDown size={12} className="muted" />
            </button>
          </span>
        </div>
        {inlineFields.map((f) => (
          <div className={`${rowClass(f.name)}${f.hidden ? " off-screen" : ""}`} key={f.id} title={f.hidden ? "不在问题界面上（网页中不显示）" : undefined}>
            <span className="field-name">{f.name}</span>
            <span className="field-value">
              {(f.id === "assignee" || f.id === "reporter") && <Avatar name={f.text} size={20} />}
              {f.issueKey ? <IssueKeyValue issueKey={f.issueKey} /> : <span className="ellipsis">{/^\d{4}-\d{2}-\d{2}T/.test(f.text) ? formatTime(f.text) : f.text}</span>}
            </span>
          </div>
        ))}
        {issue.timeTracking && <TimeTrackingRow tt={issue.timeTracking} />}
        {(screenFields.length > COLLAPSED_FIELD_COUNT || hiddenCount > 0) && (
          <button className="btn subtle field-toggle" onClick={() => setShowAllFields((v) => !v)}>
            {showAllFields
              ? "收起字段"
              : screenFields.length > COLLAPSED_FIELD_COUNT
                ? `显示全部 ${screenFields.length} 个字段${hiddenCount ? `（另有 ${hiddenCount} 个界面外字段）` : ""}`
                : `显示 ${hiddenCount} 个界面外字段`}
          </button>
        )}
      </section>

      <section className={`block${changed.has("描述") || changed.has("Description") ? " changed" : ""}`}>
        <h2>
          <FileText size={16} className="muted" />
          描述
        </h2>
        {issue.descriptionHtml ? <RichHtml service="jira" html={issue.descriptionHtml} /> : <p className="muted">无描述</p>}
      </section>

      {htmlFields.map((f) => (
        <section className="block" key={f.id}>
          <h2>{f.name}</h2>
          <RichHtml service="jira" html={f.html!} />
        </section>
      ))}

      <Subtasks issue={issue} onCreate={() => setCreatingSubtask(true)} />

      <Links issue={issue} onChanged={applyUpdate} />

      <SimilarList issue={issue} />

      <WikiPages issueKey={issue.key} onCount={countWiki} />

      <IssueCode issue={issue} onCount={countCode} />

      <Backlinks
        id="issue-workspace"
        onCount={countWorkspace}
        system="jira"
        itemKey={issue.key}
        title="工作空间"
        actions={
          <>
            <button
              className="btn small-btn"
              onClick={async () => {
                try {
                  await addIssueTodo(issue);
                  toast("已添加待办");
                } catch (e) {
                  setNotice(errorMessage(e));
                }
              }}
            >
              <CheckSquare size={13} />
              添加待办
            </button>
            <button
              className="btn small-btn"
              onClick={async () => {
                try {
                  const doc = await createIssueNote(issue);
                  navigate({ page: "notes", docId: doc.id });
                } catch (e) {
                  setNotice(errorMessage(e));
                }
              }}
            >
              <NotepadText size={13} />
              写笔记
            </button>
            <button
              className="btn small-btn"
              onClick={async () => {
                try {
                  const doc = await issueToPage(issue.key, baseUrl);
                  navigate({ page: "kb", docId: doc.id });
                } catch (e) {
                  setNotice(errorMessage(e));
                }
              }}
            >
              <BookOpen size={13} />
              沉淀到知识库
            </button>
          </>
        }
      />

      <Attachments issueKey={issue.key} attachments={issue.attachments} onUploaded={(added) => setIssue({ ...issue, attachments: [...issue.attachments, ...added] })} />

      <IssueActivity issue={issue} newSince={changes?.since ?? null} onCommentsChanged={(comments) => setIssue({ ...issue, comments })} onTimeChanged={reloadIssue} />

      {activeTransition && (
        <TransitionDialog
          issueKey={issue.key}
          projectKey={projectKeyOf(issue.key)}
          transition={activeTransition.transition}
          template={activeTransition.template}
          issue={issue}
          onClose={() => setActiveTransition(null)}
          onDone={(detail) => {
            setActiveTransition(null);
            applyUpdate(detail);
          }}
        />
      )}
      {editing && (
        <EditIssueDialog
          issueKey={issue.key}
          onClose={() => setEditing(false)}
          onDone={(detail) => {
            setEditing(false);
            applyUpdate(detail);
          }}
        />
      )}
      {priorityMenu.menu}
      {assigning && (
        <AssignDialog
          issue={issue}
          onClose={() => setAssigning(false)}
          onDone={(detail) => {
            setAssigning(false);
            applyUpdate(detail);
          }}
        />
      )}
      {creatingSubtask && (
        <CreateIssueDialog
          parent={issue}
          onClose={() => setCreatingSubtask(false)}
          onCreated={(key, warning) => {
            setCreatingSubtask(false);
            setNotice(warning ? `已创建 ${key}，但${warning}` : null);
            reloadIssue();
          }}
        />
      )}
    </div>
  );
}

/** 引用了这个问题的 Wiki 页面（页面中的 Jira 宏、正文中的问题键）。 */
type RelatedKind = "code" | "wiki" | "workspace";
const RELATED: [RelatedKind, string, string][] = [
  ["code", "代码", "issue-code"],
  ["wiki", "Wiki", "issue-wiki"],
  ["workspace", "工作空间", "issue-workspace"],
];

/** 标题下方的一行关联摘要，点击滚动到对应区块。 */
function RelatedSummary({ counts }: { counts: Record<RelatedKind, number> }) {
  const items = RELATED.filter(([kind]) => counts[kind] > 0);
  if (items.length === 0) return null;
  return (
    <div className="issue-related muted small">
      {items.map(([kind, label, id], i) => (
        <span key={kind}>
          {i > 0 && " · "}
          <button className="link-plain" onClick={() => document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" })}>
            {label} {counts[kind]}
          </button>
        </span>
      ))}
    </div>
  );
}

function WikiPages({ issueKey, onCount }: { issueKey: string; onCount?: (n: number) => void }) {
  const { isReady } = useSettings();
  const { navigate } = useNav();
  const menus = useMenus();
  const [pages, setPages] = useState<WikiPageHit[] | null>(null);
  const ready = isReady("confluence");
  useEffect(() => {
    if (!ready) return;
    let alive = true;
    setPages(null);
    api.wikiIssuePages(issueKey).then(
      (list) => alive && setPages(list),
      () => alive && setPages([]),
    );
    return () => {
      alive = false;
    };
  }, [issueKey, ready]);
  useEffect(() => {
    onCount?.(pages?.length ?? 0);
  }, [pages, onCount]);
  if (!ready || !pages || pages.length === 0) return null;
  return (
    <section className="block" id="issue-wiki">
      <h2>
        <BookText size={16} className="muted" />
        Wiki 页面 <span className="count">{pages.length}</span>
      </h2>
      <ul className="links">
        {pages.map((p) => (
          <li
            key={p.id}
            className={`clickable${menus.target === p.id ? " menu-target" : ""}`}
            onClick={() => navigate({ page: "wiki", wikiPage: p.id })}
            onContextMenu={(e) => menus.open(e, menus.wikiPage({ id: p.id, title: p.title, space: p.spaceName }), p.id)}
          >
            <BookText size={13} className="muted" />
            <span className="ellipsis grow">{p.title}</span>
            <span className="muted small nowrap">
              {p.spaceName}
              {p.modified && ` · ${formatTime(p.modified)}`}
            </span>
          </li>
        ))}
      </ul>
    </section>
  );
}

/** 指向另一个问题的字段值（例如 Epic 链接）：显示概要，点击在应用内打开。 */
function IssueKeyValue({ issueKey }: { issueKey: string }) {
  const { navigate } = useNav();
  const menus = useMenus();
  const [summary, setSummary] = useState<string | null>(null);
  useEffect(() => {
    api.jiraPickIssues(issueKey, null, false).then((list) => setSummary(list.find((i) => i.key === issueKey)?.summary ?? null), () => {});
  }, [issueKey]);
  return (
    <button className="link ellipsis" onClick={() => navigate({ page: "jira", issueKey })} onContextMenu={(e) => menus.open(e, menus.issue({ key: issueKey, summary: summary ?? undefined }))} title={summary ? `${issueKey} ${summary}` : issueKey}>
      {summary ?? issueKey}
    </button>
  );
}

/** 关注 / 取消关注，显示关注人数。 */
function WatchButton({ issueKey }: { issueKey: string }) {
  const [watchers, setWatchers] = useState<Watchers | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    api.jiraWatchers(issueKey).then(setWatchers, () => setWatchers(null));
  }, [issueKey]);
  if (!watchers) return null;
  const toggle = async () => {
    setBusy(true);
    try {
      setWatchers(await api.jiraSetWatching(issueKey, !watchers.watching));
    } catch (e) {
      toast(`操作失败：${errorMessage(e)}`, true);
    } finally {
      setBusy(false);
    }
  };
  return (
    <button
      className={`btn${watchers.watching ? " on" : ""}`}
      disabled={busy}
      onClick={toggle}
      title={`${watchers.watching ? "取消关注（不再收到这个问题的动态）" : "关注（问题有变化时提醒我）"}${watchers.count > 0 ? `\n${watchers.count} 人关注` : ""}`}
    >
      <Eye size={14} />
      {watchers.count > 0 && <span className="muted">{watchers.count}</span>}
    </button>
  );
}

/** 上次查看之后别人做的修改：每次修改的字段，以及新评论（点击跳到评论）。 */
function ChangesSince({ since, history, loading, issue, onDismiss }: { since: number; history: HistoryEntry[]; loading: boolean; issue: IssueDetail; onDismiss: () => void }) {
  const comments = issue.comments.filter((c) => !c.mine && parseTime(c.created).getTime() > since);
  const commenters = [...new Set(comments.map((c) => c.author))];
  if (!loading && history.length === 0 && comments.length === 0) return null;
  const recent = [...history].reverse().slice(0, 6);
  return (
    <div className="changes-banner">
      <div className="changes-title">
        <History size={14} />
        <span className="grow">
          上次查看（{formatTime(new Date(since).toISOString())}）之后{loading ? "，正在查找变化…" : "的变化"}
        </span>
        <button className="btn subtle icon" title="知道了" onClick={onDismiss}>
          <X size={14} />
        </button>
      </div>
      <ul>
        {recent.map((h) => (
          <li key={h.id}>
            <strong>{h.author}</strong> 修改了{" "}
            {h.items.map((item, i) => (
              <span key={i}>
                {i > 0 && "、"}
                {item.field}
                {/* 状态这类短值直接显示变化 */}
                {item.to && item.to.length <= 16 && (item.from ?? "").length <= 16 && (
                  <span className="muted">
                    （{item.from ?? "无"} → {item.to}）
                  </span>
                )}
              </span>
            ))}
            <span className="muted small"> · {formatTime(h.created)}</span>
          </li>
        ))}
        {history.length > recent.length && <li className="muted small">还有 {history.length - recent.length} 次修改，见“历史记录”</li>}
        {comments.length > 0 && (
          <li>
            <button className="link" onClick={() => document.getElementById(`comment-${comments[0].id}`)?.scrollIntoView({ behavior: "smooth", block: "center" })}>
              {commenters.join("、")} 添加了 {comments.length} 条评论
            </button>
          </li>
        )}
      </ul>
    </div>
  );
}

/** 相似问题：概要相近的其他问题，默认只看已解决的，并显示解决情况和最后的评论，便于参考别人的处理方式。 */
function SimilarList({ issue }: { issue: IssueDetail }) {
  const { navigate } = useNav();
  const [resolvedOnly, setResolvedOnly] = useState(true);
  const [result, setResult] = useState<SimilarIssues | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    setResult(null);
    setError(null);
    api.jiraSimilarIssues(issue.key, issue.summary, resolvedOnly).then(
      (r) => alive && setResult(r),
      (e) => alive && setError(errorMessage(e)),
    );
    return () => {
      alive = false;
    };
  }, [issue.key, issue.summary, resolvedOnly]);
  if (result && !result.jql) return null;
  return (
    <section className="block">
      <h2>
        <Sparkles size={16} className="muted" />
        相似问题
        {result && <span className="muted small similar-source">{result.source === "local" ? "本机问题库" : "Jira 搜索"}</span>}
        <span className="spacer" />
        <label className="checkbox small">
          <input type="checkbox" checked={resolvedOnly} onChange={(e) => setResolvedOnly(e.target.checked)} />
          只看已解决
        </label>
        {result?.jql && result.issues.length > 0 && (
          <button className="btn subtle small-btn" onClick={() => navigate({ page: "jira", jql: result.jql! })}>
            在列表中查看更多
          </button>
        )}
      </h2>
      {error && <ErrorBox message={error} />}
      {!result && !error && <Skeleton lines={3} />}
      {result && result.issues.length === 0 && <p className="muted small">没有找到相似的问题</p>}
      {result && result.issues.length > 0 && (
        <ul className="similar-list">
          {result.issues.map((i) => (
            <SimilarItem key={i.key} hit={i} onOpen={() => navigate({ page: "jira", issueKey: i.key })} />
          ))}
        </ul>
      )}
    </section>
  );
}

/** 一条相似问题：概要、经办人、状态；下面是解决结果、用时和最后的评论。 */
function SimilarItem({ hit: i, onOpen }: { hit: IssueHit; onOpen: () => void }) {
  const menus = useMenus();
  const [expanded, setExpanded] = useState(false);
  const days = i.resolved ? Math.max(0, Math.round((parseTime(i.resolved).getTime() - parseTime(i.created).getTime()) / 86400000)) : null;
  const facts = [i.resolution, i.resolved && `${formatTime(i.resolved)} 解决`, days !== null && (days === 0 ? "当天解决" : `用时 ${days} 天`), i.commentCount > 0 && `${i.commentCount} 条评论`].filter(Boolean);
  const comments = expanded ? i.lastComments : i.lastComments.slice(-1);
  return (
    <li className="similar-entry">
      <button className={`similar-item${menus.target === i.key ? " menu-target" : ""}`} onClick={onOpen} onContextMenu={(e) => menus.open(e, menus.issue(i), i.key)}>
        <SysImg service="jira" src={i.issueType.iconUrl} className="icon16" />
        <span className="issue-key nowrap">{i.key}</span>
        <span className="ellipsis grow" title={i.summary}>
          {i.summary}
        </span>
        {i.assignee && (
          <span className="similar-person nowrap" title={`经办人：${i.assignee}`}>
            <Avatar name={i.assignee} size={18} />
            {i.assignee}
          </span>
        )}
        <StatusPill status={i.status} />
      </button>
      {(facts.length > 0 || comments.length > 0) && (
        <div className="similar-detail">
          {facts.length > 0 && <div className="muted small">{facts.join(" · ")}</div>}
          {comments.map((c, n) => (
            <div key={n} className={`similar-comment small${expanded ? "" : " clamp"}`} title={expanded ? undefined : c.body}>
              <strong>{c.author}</strong>：{c.body}
            </div>
          ))}
          {i.lastComments.length > 1 && (
            <button className="link small" onClick={() => setExpanded((v) => !v)}>
              {expanded ? "收起" : `最后 ${i.lastComments.length} 条评论`}
            </button>
          )}
        </div>
      )}
    </li>
  );
}

/** 时间跟踪：耗费 / 剩余 / 初始估算，以及进度条。 */
function TimeTrackingRow({ tt }: { tt: TimeTracking }) {
  const spent = tt.timeSpentSeconds ?? 0;
  const remaining = tt.remainingEstimateSeconds ?? 0;
  const total = Math.max(spent + remaining, tt.originalEstimateSeconds ?? 0, 1);
  return (
    <div className="field-row time-tracking">
      <span className="field-name">时间跟踪</span>
      <span className="field-value">
        <span className="tt-bar" title={`已耗费 ${tt.timeSpent ?? "0"}，剩余 ${tt.remainingEstimate ?? "0"}`}>
          <span style={{ width: `${(spent / total) * 100}%` }} />
        </span>
        <span className="small nowrap">
          已耗费 {tt.timeSpent ?? "0"} · 剩余 {tt.remainingEstimate ?? "0"}
          {tt.originalEstimate && <span className="muted"> · 初始估算 {tt.originalEstimate}</span>}
        </span>
      </span>
    </div>
  );
}

function Attachments({ issueKey, attachments, onUploaded }: { issueKey: string; attachments: Attachment[]; onUploaded: (added: Attachment[]) => void }) {
  const { sessionVersion } = useSettings();
  const [failedThumbs, setFailedThumbs] = useState<string[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  // 网页登录后重新尝试加载缩略图
  useEffect(() => setFailedThumbs([]), [sessionVersion]);

  const block = useRef<HTMLElement>(null);
  const upload = useCallback(
    async (paths: string[]) => {
      if (paths.length === 0) return;
      setError(null);
      setBusy(`正在上传 ${paths.length} 个文件…`);
      // 拖放时附件区可能不在视野内，滚动过去并用浮动提示告知进度
      block.current?.scrollIntoView({ behavior: "smooth", block: "nearest" });
      toast(`正在上传 ${paths.length} 个文件到 ${issueKey}…`);
      try {
        const added = await api.jiraUploadAttachments(issueKey, paths);
        onUploaded(added);
        toast(`已上传 ${added.length} 个附件到 ${issueKey}`);
      } catch (e) {
        setError(errorMessage(e));
        toast(`上传失败：${errorMessage(e)}`, true);
      } finally {
        setBusy(null);
      }
    },
    [issueKey, onUploaded],
  );

  // 把文件拖进窗口（不是拖到评论等编辑区）即可上传到当前问题
  useDropTarget(`上传到 ${issueKey} 的附件`, upload);

  const pick = async () => {
    const selected = await openDialog({ multiple: true, directory: false });
    if (selected) void upload(Array.isArray(selected) ? selected : [selected]);
  };

  const [previewing, setPreviewing] = useState<number | null>(null);
  const attachmentMenu = useContextMenu();

  const openAttachment = async (a: Attachment) => {
    setError(null);
    setBusy(`正在下载 ${a.filename}…`);
    // 预览窗口打开时下面的提示被挡住，同时用浮动提示告知进度
    toast(`正在下载 ${a.filename}…`);
    try {
      await api.jiraOpenAttachment(a.contentUrl, a.filename);
      toast("已保存到“下载”文件夹并打开");
    } catch (e) {
      setError(errorMessage(e));
      toast(`下载失败：${errorMessage(e)}`, true);
    } finally {
      setBusy(null);
    }
  };

  return (
    <section className="block" ref={block}>
      <div className="block-title">
        <h2>
          <Paperclip size={16} className="muted" />
          附件 {attachments.length > 0 && <span className="count">{attachments.length}</span>}
        </h2>
        <button className="btn" onClick={pick} disabled={busy !== null}>
          <Upload size={14} />
          上传附件
        </button>
      </div>
      {busy && <p className="muted small">{busy}</p>}
      {error && <ErrorBox message={error} />}
      <div className="attachments">
        {attachments.map((a) => (
          <button
            key={a.id}
            className={`attachment${attachmentMenu.target === a.id ? " menu-target" : ""}`}
            onClick={() => setPreviewing(attachments.indexOf(a))}
            onContextMenu={(e) =>
              attachmentMenu.open(e, attachmentItems(a, () => setPreviewing(attachments.indexOf(a)), openAttachment), a.id)
            }
            title={`${a.filename}\n${a.author} · ${formatTime(a.created)}\n点击预览，右键可用系统应用打开`}
          >
            {a.thumbnailUrl && !failedThumbs.includes(a.id) ? (
              <img src={assetUrl("jira", a.thumbnailUrl, sessionVersion)} alt="" loading="lazy" onError={() => setFailedThumbs((list) => [...list, a.id])} />
            ) : (
              <span className="file-icon">
                <FileText size={20} />
                {fileExt(a.filename)}
              </span>
            )}
            <span className="attachment-name">{a.filename}</span>
            <span className="muted small">{formatSize(a.size)}</span>
          </button>
        ))}
        <div className="drop-hint muted small">
          <Upload size={13} />
          把文件拖进窗口即可上传；拖到评论框会插入到评论中
        </div>
      </div>
      {attachmentMenu.menu}
      {previewing !== null && attachments[previewing] && <AttachmentViewer attachments={attachments} index={previewing} onClose={() => setPreviewing(null)} onOpenExternal={(a) => void openAttachment(a)} />}
    </section>
  );
}

function fileExt(name: string): string {
  const ext = name.includes(".") ? name.split(".").pop()! : "file";
  return ext.slice(0, 4).toUpperCase();
}
