// Jira 问题的右键菜单：问题列表、首页“我的问题”等共用。
import { useMemo, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { ArrowRightLeft, BookOpen, CheckSquare, CircleDot, Copy, ExternalLink, Flag, Link, NotepadText, Timer, UserRound, Zap } from "lucide-react";
import { currentTimer, isTiming, requestStop, startTimer } from "../../lib/timer";
import { api, errorMessage, type IssueDetail, type IssueSummary, type Transition, type UserRef } from "../../api";
import { ErrorBox, Modal, SysImg } from "../../components/common";
import type { MenuInput } from "../../components/ContextMenu";
import { guarded, toast } from "../../components/Toast";
import { copyText } from "../../lib/clipboard";
import { useTemplates, type JiraTemplate } from "../../lib/templates";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { addIssueTodo, createIssueNote } from "../workspace/issueActions";
import { issueToPage } from "../workspace/kbImport";
import { Picker } from "./fieldForm";
import { projectKeyOf } from "./jql";
import { TransitionDialog } from "./TransitionDialog";

/** 菜单针对的问题：完整的列表项，或只知道问题键（和概要）时按需查询其余字段。 */
export type IssueTarget = IssueSummary | { key: string; summary?: string };

export interface IssueMenuOptions {
  /** 当前正在查看这个问题（不显示“打开”） */
  current?: boolean;
  /** 流转、分配、改优先级成功后调用（覆盖 useIssueMenu 的 onUpdated） */
  onUpdated?: (issue: IssueDetail) => void;
}

const isSummary = (issue: IssueTarget): issue is IssueSummary => "assigneeName" in issue && "priority" in issue;

/** 按问题键查询列表项需要的字段。 */
export async function fetchIssueSummary(key: string): Promise<IssueSummary> {
  const issue = (await api.jiraSearch(`key = ${key}`, 0, 1)).issues[0];
  if (!issue) throw new Error(`找不到问题 ${key}（可能没有权限）`);
  return issue;
}

/**
 * 问题菜单及其需要的对话框（填写字段的流转、分配给其他人）。
 * 问题列表、首页、问题详情、Wiki 和笔记中的问题链接等处共用，保证同一个问题在哪里右键都是同一份菜单。
 * `onUpdated` 在流转、分配、改优先级成功后调用，用于刷新列表。
 */
export function useIssueMenu(onUpdated?: (issue: IssueDetail) => void) {
  const { baseUrl } = useSettings();
  const { navigate } = useNav();
  type Done = ((issue: IssueDetail) => void) | undefined;
  const [transition, setTransition] = useState<{ issue: IssueSummary; transition: Transition; template?: JiraTemplate; done: Done } | null>(null);
  const templates = useTemplates();
  const [assigning, setAssigning] = useState<{ issue: IssueSummary; done: Done } | null>(null);
  const jiraBase = baseUrl("jira");

  const updated = (done: Done, detail: IssueDetail, message: string) => {
    (done ?? onUpdated)?.(detail);
    toast(message);
  };

  const menuFor = (target: IssueTarget | string, options: IssueMenuOptions = {}): MenuInput[] => {
    const brief = typeof target === "string" ? { key: target } : target;
    const key = brief.key;
    const done = options.onUpdated;
    let pending: Promise<IssueSummary> | null = isSummary(brief) ? Promise.resolve(brief) : null;
    const full = () => (pending ??= fetchIssueSummary(key));
    const summary = async () => brief.summary ?? (await full()).summary;
    const url = `${jiraBase}/browse/${key}`;
    const copy = (text: () => string | Promise<string>) =>
      guarded(async () => {
        await copyText(await text());
        toast("已复制");
      });
    return [
      !options.current && { label: `打开 ${key}`, icon: <CircleDot size={14} />, onSelect: () => navigate({ page: "jira", issueKey: key }) },
      "separator",
      {
        label: "流转",
        icon: <ArrowRightLeft size={14} />,
        loadChildren: async () => {
          const [available, issue] = await Promise.all([api.jiraTransitions(key), full()]);
          // 流转模板打开预先填好的对话框，确认后提交
          const usable = templates.flatMap((tpl) => {
            const t = tpl.kind === "transition" && available.find((x) => x.name === tpl.transition);
            return t ? [{ tpl, t }] : [];
          });
          return [
            ...available.map((t) => ({
              // 需要填写字段的流转打开对话框；其余再点一次确认后直接执行，避免误点
              label: t.fields.length > 0 ? `${t.name}…` : t.name,
              confirm: t.fields.length > 0 ? undefined : `再点一次确认「${t.name}」`,
              onSelect: t.fields.length > 0 ? () => setTransition({ issue, transition: t, done }) : guarded(async () => updated(done, await api.jiraTransition(key, t.id, {}, null), `${key} 已流转到「${t.to.name}」`)),
            })),
            usable.length > 0 && "separator",
            ...usable.map(({ tpl, t }) => ({ label: `${tpl.name}…`, icon: <Zap size={14} />, onSelect: () => setTransition({ issue, transition: t, template: tpl, done }) })),
          ];
        },
      },
      {
        label: "分配",
        icon: <UserRound size={14} />,
        loadChildren: async () => {
          const [me, issue] = await Promise.all([api.jiraMe(), full()]);
          return [
            { label: "分配给我", disabled: issue.assigneeName === me, onSelect: guarded(async () => updated(done, await api.jiraAssign(key, me), `${key} 已分配给你`)) },
            { label: "分配给…", onSelect: () => setAssigning({ issue, done }) },
            "separator",
            { label: "取消分配", disabled: !issue.assigneeName, onSelect: guarded(async () => updated(done, await api.jiraAssign(key, null), `${key} 已取消分配`)) },
          ];
        },
      },
      {
        label: "优先级",
        icon: <Flag size={14} />,
        loadChildren: async () => {
          const [list, issue] = await Promise.all([api.jiraPriorities(), full()]);
          return list.map((p) => ({
            label: p.name,
            checked: issue.priority?.name === p.name,
            icon: <SysImg service="jira" src={p.iconUrl} className="icon16" />,
            onSelect: issue.priority?.name === p.name ? undefined : guarded(async () => updated(done, await api.jiraSetPriority(key, p.id), `${key} 优先级已改为「${p.name}」`)),
          }));
        },
      },
      isTiming(currentTimer(), { issueKey: key })
        ? { label: "停止计时并登记…", icon: <Timer size={14} />, onSelect: () => requestStop() }
        : { label: "开始计时", icon: <Timer size={14} />, onSelect: guarded(async () => startTimer({ issueKey: key, title: await summary() })) },
      "separator",
      { label: "复制问题键", icon: <Copy size={14} />, onSelect: copy(() => key) },
      { label: "复制问题键和概要", onSelect: copy(async () => `${key} ${await summary()}`) },
      { label: "复制链接", icon: <Link size={14} />, onSelect: copy(() => url) },
      { label: "复制为 Markdown 链接", onSelect: copy(async () => `[${key} ${await summary()}](${url})`) },
      "separator",
      {
        label: "添加待办",
        icon: <CheckSquare size={14} />,
        onSelect: guarded(async () => {
          await addIssueTodo({ key, summary: await summary() });
          toast(`已为 ${key} 添加待办`);
        }),
      },
      { label: "写笔记", icon: <NotepadText size={14} />, onSelect: guarded(async () => navigate({ page: "notes", docId: (await createIssueNote({ key, summary: await summary() })).id })) },
      { label: "沉淀到知识库", icon: <BookOpen size={14} />, onSelect: guarded(async () => navigate({ page: "kb", docId: (await issueToPage(key, jiraBase)).id })) },
      "separator",
      { label: "在浏览器中打开", icon: <ExternalLink size={14} />, onSelect: guarded(() => openUrl(url)) },
    ];
  };

  const dialogs = (
    <>
      {transition && (
        <TransitionDialog
          issueKey={transition.issue.key}
          projectKey={projectKeyOf(transition.issue.key)}
          transition={transition.transition}
          issue={transition.issue}
          template={transition.template}
          onClose={() => setTransition(null)}
          onDone={(detail) => {
            setTransition(null);
            updated(transition.done, detail, `${detail.key} 已流转到「${detail.status.name}」`);
          }}
        />
      )}
      {assigning && (
        <AssignDialog
          issue={assigning.issue}
          onClose={() => setAssigning(null)}
          onDone={(detail) => {
            setAssigning(null);
            updated(assigning.done, detail, `${detail.key} 已分配给 ${detail.assignee ?? "未分配"}`);
          }}
        />
      )}
    </>
  );

  return { menuFor, dialogs };
}

// 分配对话框中的两个特殊选项；“自动”交给 Jira 按项目的默认经办人分配
const UNASSIGNED: UserRef = { name: "", displayName: "未分配" };
const AUTOMATIC: UserRef = { name: "-1", displayName: "自动" };

/** 把问题分配给某个可分配的用户。 */
export function AssignDialog({ issue, onClose, onDone }: { issue: { key: string; assignee: string | null }; onClose: () => void; onDone: (issue: IssueDetail) => void }) {
  const [user, setUser] = useState<UserRef | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 与网页一致：未输入时列出“建议”（最近分配过的人等），再加上“未分配”“自动”
  const suggested = useMemo(() => api.jiraSuggestedAssignees(issue.key).catch(() => [] as UserRef[]), [issue.key]);
  const search = async (q: string): Promise<UserRef[]> => {
    if (q.trim()) return api.jiraFindUsers(q.trim(), "assignee", issue.key, null);
    return [...(await suggested), UNASSIGNED, AUTOMATIC];
  };
  const assign = async () => {
    if (!user) return;
    setBusy(true);
    setError(null);
    try {
      onDone(await api.jiraAssign(issue.key, user === UNASSIGNED ? null : user.name));
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };
  return (
    <Modal
      title={`分配 ${issue.key}`}
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            取消
          </button>
          <button className="btn primary" disabled={!user || busy} onClick={assign}>
            {busy ? "分配中…" : "分配"}
          </button>
        </>
      }
    >
      <p className="muted small">当前经办人：{issue.assignee ?? "未分配"}</p>
      <div className="form-field">
        <span>分配给</span>
        <Picker<UserRef>
          selected={user ? [user] : []}
          onChange={(list) => setUser(list[0] ?? null)}
          search={search}
          label={(u) => u.displayName}
          detail={(u) => (u === UNASSIGNED || u === AUTOMATIC ? "" : u.name)}
          id={(u) => u.name}
          placeholder="输入姓名或用户名搜索"
          searchOnFocus
          idleHeading="建议"
        />
      </div>
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}
