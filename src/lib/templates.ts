// Jira 评论模板、流转模板。保存在工作空间中（随工作空间同步到其他设备），内容为 JSON。
import { useCallback, useEffect, useState } from "react";
import { api, TEMPLATE_KIND, type IssueSummary } from "../api";
import type { Values } from "../pages/jira/fieldForm";
import { today, useWorkspaceRefresh, workspaceChanged } from "./workspace";

export interface JiraTemplate {
  id: string;
  name: string;
  kind: "comment" | "transition";
  /** 评论内容（wiki 标记），可包含变量 */
  body: string;
  /** 流转模板：流转的名称（不同项目的工作流中 id 不同，按名称匹配） */
  transition?: string;
  /** 流转模板：流转界面上的字段值 */
  values?: Values;
}

/** 模板中可用的变量。 */
export const TEMPLATE_VARIABLES = [
  { name: "{key}", label: "问题键" },
  { name: "{summary}", label: "概要" },
  { name: "{reporter}", label: "提及报告人" },
  { name: "{assignee}", label: "经办人" },
  { name: "{today}", label: "今天的日期" },
];

export async function loadTemplates(): Promise<JiraTemplate[]> {
  const docs = await api.wsFullDocs(TEMPLATE_KIND);
  return docs.flatMap((d) => {
    try {
      const data = JSON.parse(d.content) as Omit<JiraTemplate, "id" | "name">;
      return [{ ...data, id: d.id, name: d.title }];
    } catch {
      return [];
    }
  });
}

export async function saveTemplate(t: Omit<JiraTemplate, "id"> & { id?: string }): Promise<void> {
  const { id, name, ...data } = t;
  await api.wsSaveDoc({ id: id ?? null, kind: TEMPLATE_KIND, title: name, content: JSON.stringify(data) });
  workspaceChanged();
}

export async function deleteTemplate(id: string): Promise<void> {
  await api.wsDeleteDoc(id);
  workspaceChanged();
}

/** 全部模板，工作空间数据变化（包括其他设备同步过来）时刷新。 */
export function useTemplates(): JiraTemplate[] {
  const [list, setList] = useState<JiraTemplate[]>([]);
  const reload = useCallback(() => {
    loadTemplates().then(setList, () => {});
  }, []);
  useEffect(reload, [reload]);
  useWorkspaceRefresh(reload);
  return list;
}

/** 把模板中的变量替换为当前问题的内容。 */
export function fillTemplate(body: string, issue: Pick<IssueSummary, "key" | "summary" | "reporter" | "reporterName" | "assignee">): string {
  const vars: Record<string, string> = {
    "{key}": issue.key,
    "{summary}": issue.summary,
    "{reporter}": issue.reporterName ? `[~${issue.reporterName}]` : (issue.reporter ?? ""),
    "{assignee}": issue.assignee ?? "",
    "{today}": today(),
  };
  return body.replace(/\{(key|summary|reporter|assignee|today)\}/g, (v) => vars[v] ?? v);
}
