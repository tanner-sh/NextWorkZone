// Jira 问题的右键菜单：问题列表、首页“我的问题”等共用。
import { useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { ArrowRightLeft, BookOpen, CheckSquare, Copy, ExternalLink, Flag, Link, NotepadText, Timer, UserRound, Zap } from "lucide-react";
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

/**
 * 问题菜单及其需要的对话框（填写字段的流转、分配给其他人）。
 * `onUpdated` 在流转、分配、改优先级成功后调用，用于刷新列表。
 */
export function useIssueMenu(onUpdated?: (issue: IssueDetail) => void) {
  const { baseUrl } = useSettings();
  const { navigate } = useNav();
  const [transition, setTransition] = useState<{ issue: IssueSummary; transition: Transition; template?: JiraTemplate } | null>(null);
  const templates = useTemplates();
  const [assigning, setAssigning] = useState<IssueSummary | null>(null);
  const jiraBase = baseUrl("jira");

  const updated = (detail: IssueDetail, message: string) => {
    onUpdated?.(detail);
    toast(message);
  };

  const menuFor = (issue: IssueSummary): MenuInput[] => {
    const url = `${jiraBase}/browse/${issue.key}`;
    const copy = (text: string) =>
      guarded(async () => {
        await copyText(text);
        toast("已复制");
      });
    return [
      {
        label: "流转",
        icon: <ArrowRightLeft size={14} />,
        loadChildren: async () => {
          const available = await api.jiraTransitions(issue.key);
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
              onSelect: t.fields.length > 0 ? () => setTransition({ issue, transition: t }) : guarded(async () => updated(await api.jiraTransition(issue.key, t.id, {}, null), `${issue.key} 已流转到「${t.to.name}」`)),
            })),
            usable.length > 0 && "separator",
            ...usable.map(({ tpl, t }) => ({ label: `${tpl.name}…`, icon: <Zap size={14} />, onSelect: () => setTransition({ issue, transition: t, template: tpl }) })),
          ];
        },
      },
      {
        label: "分配",
        icon: <UserRound size={14} />,
        loadChildren: async () => {
          const me = await api.jiraMe();
          return [
            { label: "分配给我", disabled: issue.assigneeName === me, onSelect: guarded(async () => updated(await api.jiraAssign(issue.key, me), `${issue.key} 已分配给你`)) },
            { label: "分配给…", onSelect: () => setAssigning(issue) },
            "separator",
            { label: "取消分配", disabled: !issue.assigneeName, onSelect: guarded(async () => updated(await api.jiraAssign(issue.key, null), `${issue.key} 已取消分配`)) },
          ];
        },
      },
      {
        label: "优先级",
        icon: <Flag size={14} />,
        loadChildren: async () =>
          (await api.jiraPriorities()).map((p) => ({
            label: p.name,
            checked: issue.priority?.name === p.name,
            icon: <SysImg service="jira" src={p.iconUrl} className="icon16" />,
            onSelect: issue.priority?.name === p.name ? undefined : guarded(async () => updated(await api.jiraSetPriority(issue.key, p.id), `${issue.key} 优先级已改为「${p.name}」`)),
          })),
      },
      isTiming(currentTimer(), { issueKey: issue.key })
        ? { label: "停止计时并登记…", icon: <Timer size={14} />, onSelect: () => requestStop() }
        : { label: "开始计时", icon: <Timer size={14} />, onSelect: () => startTimer({ issueKey: issue.key, title: issue.summary }) },
      "separator",
      { label: "复制问题键", icon: <Copy size={14} />, onSelect: copy(issue.key) },
      { label: "复制问题键和概要", onSelect: copy(`${issue.key} ${issue.summary}`) },
      { label: "复制链接", icon: <Link size={14} />, onSelect: copy(url) },
      { label: "在浏览器中打开", icon: <ExternalLink size={14} />, onSelect: guarded(() => openUrl(url)) },
      "separator",
      {
        label: "添加待办",
        icon: <CheckSquare size={14} />,
        onSelect: guarded(async () => {
          await addIssueTodo(issue);
          toast(`已为 ${issue.key} 添加待办`);
        }),
      },
      { label: "写笔记", icon: <NotepadText size={14} />, onSelect: guarded(async () => navigate({ page: "notes", docId: (await createIssueNote(issue)).id })) },
      { label: "沉淀到知识库", icon: <BookOpen size={14} />, onSelect: guarded(async () => navigate({ page: "kb", docId: (await issueToPage(issue.key, jiraBase)).id })) },
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
            updated(detail, `${detail.key} 已流转到「${detail.status.name}」`);
          }}
        />
      )}
      {assigning && (
        <AssignDialog
          issue={assigning}
          onClose={() => setAssigning(null)}
          onDone={(detail) => {
            setAssigning(null);
            updated(detail, `${detail.key} 已分配给 ${detail.assignee ?? "未分配"}`);
          }}
        />
      )}
    </>
  );

  return { menuFor, dialogs };
}

/** 把问题分配给某个可分配的用户。 */
export function AssignDialog({ issue, onClose, onDone }: { issue: { key: string; assignee: string | null }; onClose: () => void; onDone: (issue: IssueDetail) => void }) {
  const [user, setUser] = useState<UserRef | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const assign = async () => {
    if (!user) return;
    setBusy(true);
    setError(null);
    try {
      onDone(await api.jiraAssign(issue.key, user.name));
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
          search={(q) => (q.trim() ? api.jiraFindUsers(q.trim(), "assignee", issue.key, null) : [])}
          label={(u) => u.displayName}
          detail={(u) => u.name}
          id={(u) => u.name}
          placeholder="输入姓名或用户名搜索"
        />
      </div>
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}
