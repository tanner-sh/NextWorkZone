// 条目的“智能操作”：按内容识别出的问题、链接、JSON、时间戳、颜色等，提供打开、转换后粘贴、存入工作空间等操作。
import { emit } from "@tauri-apps/api/event";
import { openUrl, revealItemInDir } from "@tauri-apps/plugin-opener";
import { AppWindow, Braces, CalendarClock, CheckSquare, CircleDot, ExternalLink, FolderOpen, NotebookPen, Palette, Rows3, type LucideIcon } from "lucide-react";
import { api, WORKSPACE_SYNCED_EVENT, type ClipItem, type IssueHit, type Service } from "../../../api";
import { today, workspaceChanged } from "../../../lib/workspace";
import { docInput } from "../../workspace/docMenu";
import { colorFormats, formatDateTime, inAppLabel, issueKeys, jsonOf, linkIssueKey, timestampOf } from "./clip";

export interface ClipAction {
  id: string;
  label: string;
  icon: LucideIcon;
  /** paste：转换后粘贴；open：打开；save：存入工作空间 */
  group: "paste" | "open" | "save";
  run: () => unknown;
}

export interface ActionEnv {
  baseUrl: (service: Service) => string;
  jiraReady: boolean;
  /** 粘贴（面板中）或复制（应用内页面中、不能自动粘贴时）一段转换后的文字 */
  emitText: (text: string) => unknown;
  /** emitText 的动作名称：“粘贴”或“复制” */
  verb: string;
  /** 在主窗口中打开，格式同托盘菜单事件（`url:<地址>`、`page:<页面>`） */
  openInApp: (target: string) => unknown;
  /** 操作完成后的提示 */
  done: (message: string) => unknown;
}

/** 条目中识别出的问题 key（文字中出现的，或 Jira 链接中的）。 */
export function itemIssueKeys(item: ClipItem, env: Pick<ActionEnv, "baseUrl" | "jiraReady">): string[] {
  if (!env.jiraReady) return [];
  if (item.kind === "link") {
    const key = linkIssueKey(item.text, env.baseUrl);
    return key ? [key] : [];
  }
  return item.kind === "text" || item.kind === "code" ? issueKeys(item.text) : [];
}

/** 追加一行到今天的日记（与快速记录相同的格式）。 */
async function appendToDaily(text: string) {
  const doc = await api.wsDaily(today());
  const now = new Date();
  const line = `- ${String(now.getHours()).padStart(2, "0")}:${String(now.getMinutes()).padStart(2, "0")} ${text.replace(/\s*\n\s*/g, " ")}`;
  const content = doc.content.trim() ? `${doc.content.replace(/\s+$/, "")}\n${line}\n` : `${line}\n`;
  await api.wsSaveDoc(docInput(doc, { content, kind: "daily", title: doc.title || today() }));
}

function savedToWorkspace() {
  workspaceChanged();
  // 通知主窗口刷新
  void emit(WORKSPACE_SYNCED_EVENT, null);
}

/** `text` 是条目的完整文字（列表中的可能只有开头）。 */
export function smartActions(item: ClipItem, text: string, issues: IssueHit[], env: ActionEnv): ClipAction[] {
  const actions: ClipAction[] = [];
  const jira = env.baseUrl("jira");
  const trimmed = text.trim();
  const verb = env.verb;

  if (item.kind === "link") {
    const label = inAppLabel(trimmed, env.baseUrl);
    if (label) actions.push({ id: "open-app", label: `在应用中打开${label}`, icon: AppWindow, group: "open", run: () => env.openInApp(`url:${trimmed}`) });
    actions.push({ id: "open-browser", label: "在浏览器中打开", icon: ExternalLink, group: "open", run: () => openUrl(trimmed.startsWith("www.") ? `https://${trimmed}` : trimmed) });
  }

  for (const key of itemIssueKeys(item, env)) {
    const issue = issues.find((i) => i.key === key);
    if (item.kind !== "link") actions.push({ id: `issue-${key}`, label: `打开问题 ${key}`, icon: CircleDot, group: "open", run: () => env.openInApp(`url:${jira}/browse/${key}`) });
    if (issue) actions.push({ id: `issue-title-${key}`, label: `${verb}为“${key} ${issue.summary}”`, icon: CircleDot, group: "paste", run: () => env.emitText(`${key} ${issue.summary}`) });
    if (item.kind !== "link") actions.push({ id: `issue-url-${key}`, label: `${verb}问题链接`, icon: CircleDot, group: "paste", run: () => env.emitText(`${jira}/browse/${key}`) });
  }

  const json = item.kind === "code" ? jsonOf(text) : undefined;
  if (json !== undefined) {
    const pretty = JSON.stringify(json, null, 2);
    const compact = JSON.stringify(json);
    if (pretty !== text) actions.push({ id: "json-pretty", label: `格式化 JSON 后${verb}`, icon: Braces, group: "paste", run: () => env.emitText(pretty) });
    if (compact !== text) actions.push({ id: "json-compact", label: `压缩 JSON 后${verb}`, icon: Braces, group: "paste", run: () => env.emitText(compact) });
  }

  const time = item.kind === "text" ? timestampOf(text) : null;
  if (time) actions.push({ id: "timestamp", label: `${verb}为 ${formatDateTime(time)}`, icon: CalendarClock, group: "paste", run: () => env.emitText(formatDateTime(time)) });

  if (item.kind === "color") {
    const formats = colorFormats(text);
    for (const [name, value] of Object.entries(formats ?? {})) {
      if (value.toLowerCase() !== trimmed.toLowerCase()) actions.push({ id: `color-${name}`, label: `${verb}为 ${value}`, icon: Palette, group: "paste", run: () => env.emitText(value) });
    }
  }

  if ((item.kind === "text" || item.kind === "code") && /\n/.test(trimmed)) {
    actions.push({ id: "one-line", label: `合并为一行后${verb}`, icon: Rows3, group: "paste", run: () => env.emitText(trimmed.replace(/\s*\n\s*/g, " ")) });
  }

  if (item.kind === "file") {
    actions.push({ id: "reveal", label: "在文件夹中显示", icon: FolderOpen, group: "open", run: () => revealItemInDir(item.files) });
    actions.push({ id: "paths", label: `${verb}为文件路径`, icon: Rows3, group: "paste", run: () => env.emitText(item.files.join("\n")) });
  }

  if (item.kind === "text" || item.kind === "link" || item.kind === "code") {
    const [first, ...rest] = trimmed.split("\n");
    const title = (item.title || first).trim().slice(0, 200);
    // 起了名字的条目以名字作标题，原文全部放进备注（链接不会丢）
    const notes = (item.title ? trimmed : rest.join("\n")).trim();
    actions.push({
      id: "todo",
      label: "加入待办",
      icon: CheckSquare,
      group: "save",
      run: async () => {
        await api.wsSaveTodo({ title, notes, due: null });
        savedToWorkspace();
        env.done("已加入待办");
      },
    });
    actions.push({
      id: "daily",
      label: "追加到今天的日记",
      icon: NotebookPen,
      group: "save",
      run: async () => {
        await appendToDaily(trimmed);
        savedToWorkspace();
        env.done("已写入今天的日记");
      },
    });
  }
  return actions;
}
