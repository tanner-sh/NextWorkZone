// 从 Jira 问题生成工作空间内容：问题详情页和问题列表的右键菜单共用。
import { api, type Doc, type Todo } from "../../api";
import { workspaceChanged } from "../../lib/workspace";

interface IssueBrief {
  key: string;
  summary: string;
}

/** 为问题添加一条关联的待办。 */
export async function addIssueTodo(issue: IssueBrief): Promise<Todo> {
  const todo = await api.wsSaveTodo({ title: issue.summary, refSystem: "jira", refKey: issue.key, refTitle: issue.summary });
  workspaceChanged();
  return todo;
}

/** 新建一篇引用该问题的笔记。 */
export async function createIssueNote(issue: IssueBrief): Promise<Doc> {
  const doc = await api.wsSaveDoc({ kind: "note", title: `${issue.key} ${issue.summary}`, content: `${issue.key}\n\n` });
  workspaceChanged();
  return doc;
}
