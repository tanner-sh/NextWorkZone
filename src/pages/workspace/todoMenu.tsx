// 待办的右键菜单：待办页和首页“今天的待办”共用。
import { CalendarDays, Check, CircleDot, Copy, ExternalLink, Flag, RotateCcw, Timer, Trash2 } from "lucide-react";
import { currentTimer, isTiming, requestStop, startTimer } from "../../lib/timer";
import { api, type Todo, type TodoInput } from "../../api";
import type { MenuEntry } from "../../components/ContextMenu";
import { guarded, toast } from "../../components/Toast";
import { copyText } from "../../lib/clipboard";
import { addDays, nextMonday, today, workspaceChanged } from "../../lib/workspace";
import type { NavTarget } from "../../state/nav";

/** 由“分配给我的 Jira 问题”自动生成的待办；删除后同步时不会再添加。 */
export const fromJiraSync = (todo: Todo) => todo.id.startsWith("jira-");

export const PRIORITIES = ["无", "低", "中", "高"];

/** 保存时需要提交完整字段。 */
export function todoInput(todo: Todo, patch: Partial<Todo> = {}): TodoInput {
  const next = { ...todo, ...patch };
  return {
    id: next.id,
    title: next.title,
    notes: next.notes,
    done: next.done,
    due: next.due,
    priority: next.priority,
    refSystem: next.refSystem,
    refKey: next.refKey,
    refTitle: next.refTitle,
  };
}

/** 待办的计时目标：关联了 Jira 问题时登记到该问题。 */
export function todoTimerTarget(todo: Todo) {
  const jira = todo.refSystem === "jira";
  return { todoId: todo.id, issueKey: jira ? todo.refKey : null, issueSummary: jira ? todo.refTitle : null, title: todo.title || "无标题待办" };
}

interface Options {
  /** 保存成功后的回调（更新列表） */
  onSaved: (todo: Todo) => void;
  onDeleted: (todo: Todo) => void;
  navigate: (target: NavTarget) => void;
  /** 提供时显示“创建为 Jira 问题” */
  onPromote?: (todo: Todo) => void;
}

export function todoMenu(todo: Todo, { onSaved, onDeleted, navigate, onPromote }: Options): MenuEntry[] {
  const run = guarded;
  const save = (patch: Partial<Todo>) =>
    run(async () => {
      onSaved(await api.wsSaveTodo(todoInput(todo, patch)));
      workspaceChanged();
    });
  const dueOption = (label: string, due: string | null): MenuEntry => ({ label, checked: todo.due === due, onSelect: save({ due }) });

  return [
    {
      label: todo.done ? "标记为未完成" : "标记为完成",
      icon: todo.done ? <RotateCcw size={14} /> : <Check size={14} />,
      onSelect: run(async () => {
        onSaved(await api.wsSetTodoDone(todo.id, !todo.done));
        workspaceChanged();
      }),
    },
    "separator",
    {
      label: "截止日期",
      icon: <CalendarDays size={14} />,
      children: [dueOption("今天", today()), dueOption("明天", addDays(today(), 1)), dueOption("下周一", nextMonday()), "separator", { label: "清除截止日期", disabled: !todo.due, onSelect: save({ due: null }) }],
    },
    {
      label: "优先级",
      icon: <Flag size={14} />,
      children: [3, 2, 1, 0].map((p) => ({ label: PRIORITIES[p], checked: todo.priority === p, icon: p > 0 ? <Flag size={14} className={`prio-flag prio-${p}`} /> : undefined, onSelect: save({ priority: p }) })),
    },
    "separator",
    todo.refSystem === "jira" && todo.refKey && { label: `打开 ${todo.refKey}`, icon: <ExternalLink size={14} />, onSelect: () => navigate({ page: "jira", issueKey: todo.refKey! }) },
    todo.refSystem === "wiki" && todo.refKey && { label: "打开 Wiki 页面", icon: <ExternalLink size={14} />, onSelect: () => navigate({ page: "wiki", wikiPage: todo.refKey! }) },
    todo.refSystem === "doc" &&
      todo.refKey && {
        label: "打开来源文档",
        icon: <ExternalLink size={14} />,
        onSelect: run(async () => {
          const doc = await api.wsDoc(todo.refKey!);
          if (doc) navigate({ page: doc.kind === "page" ? "kb" : "notes", docId: doc.id });
          else toast("来源文档已被删除", true);
        }),
      },
    !todo.done &&
      (isTiming(currentTimer(), { todoId: todo.id })
        ? { label: "停止计时并登记…", icon: <Timer size={14} />, onSelect: () => requestStop() }
        : { label: "开始计时", icon: <Timer size={14} />, onSelect: () => startTimer(todoTimerTarget(todo)) }),
    !todo.refKey && onPromote && { label: "创建为 Jira 问题", icon: <CircleDot size={14} />, onSelect: () => onPromote(todo) },
    {
      label: "复制标题",
      icon: <Copy size={14} />,
      onSelect: run(async () => {
        await copyText(todo.title);
        toast("已复制");
      }),
    },
    "separator",
    {
      label: todo.refSystem === "jira" ? "删除待办（不影响 Jira 问题）" : todo.source === "wiki" ? "删除待办（不影响 Wiki 任务）" : "删除",
      icon: <Trash2 size={14} />,
      danger: true,
      confirm: fromJiraSync(todo) ? "再点一次确认（之后不再自动添加）" : "再点一次确认删除",
      onSelect: run(async () => {
        await api.wsDeleteTodo(todo.id);
        onDeleted(todo);
        workspaceChanged();
      }),
    },
  ].filter(Boolean) as MenuEntry[];
}
