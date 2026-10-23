// 把外部内容沉淀为知识库页面：Jira 问题（描述、解决方案等富文本字段、评论）、Wiki 页面。
import { api, type Doc } from "../../api";
import { formatTime } from "../../lib/format";
import { workspaceChanged } from "../../lib/workspace";
import { htmlToMarkdown } from "./editor/convert";

/** 由 Jira 问题生成知识库页面并保存，返回新页面。 */
export async function issueToPage(key: string, jiraBase: string, parentId: string | null = null): Promise<Doc> {
  const [issue, editable] = await Promise.all([api.jiraIssue(key), api.jiraEditFields(key).catch(() => [])]);
  // 多行文本字段（解决方案、原因分析等），即使内容是纯文本也要带上
  const textareas = new Set(editable.filter((f) => f.kind === "textarea" && f.key !== "description").map((f) => f.key));
  const url = `${jiraBase}/browse/${issue.key}`;
  const parts: string[] = [`> 来源：[${issue.key} ${issue.summary}](${url}) · ${issue.issueType.name} · ${issue.status.name}${issue.resolution ? ` · ${issue.resolution}` : ""}`];
  if (issue.descriptionHtml) parts.push("## 问题描述", htmlToMarkdown(issue.descriptionHtml, jiraBase));
  // 其他富文本字段（解决方案、原因分析等）
  for (const field of issue.fields.filter((f) => f.html || textareas.has(f.id))) {
    parts.push(`## ${field.name}`, field.html ? htmlToMarkdown(field.html, jiraBase) : field.text);
  }
  if (issue.comments.length > 0) {
    parts.push("## 讨论记录");
    for (const c of issue.comments) {
      parts.push(`**${c.author}** · ${formatTime(c.created)}`, htmlToMarkdown(c.bodyHtml, jiraBase));
    }
  }
  const doc = await api.wsSaveDoc({
    kind: "page",
    title: issue.summary,
    content: parts.join("\n\n"),
    parentId,
    sourceSystem: "jira",
    sourceKey: issue.key,
    sourceUrl: url,
  });
  workspaceChanged();
  return doc;
}

/** 剪藏的正文：来源说明加上页面内容。 */
async function clipContent(page: string, wikiBase: string) {
  const view = await api.wsWikiPage(page);
  const content = `> 剪藏自 Wiki：[${view.title}](${view.url})\n\n${htmlToMarkdown(view.html, wikiBase)}`;
  // 地址带上剪藏时的版本，之后据此判断原页面是否有更新
  return { view, content, sourceUrl: `${view.url}&pageVersion=${view.version}` };
}

/** 剪藏 Wiki 页面（地址或页面 id）为知识库页面，返回新页面。 */
export async function wikiToPage(page: string, wikiBase: string, parentId: string | null = null): Promise<Doc> {
  const { view, content, sourceUrl } = await clipContent(page, wikiBase);
  const doc = await api.wsSaveDoc({
    kind: "page",
    title: view.title,
    content,
    parentId,
    sourceSystem: "wiki",
    sourceKey: view.id,
    sourceUrl,
  });
  workspaceChanged();
  return doc;
}

/** 用原页面的最新内容重新剪藏（替换正文），返回更新后的页面。 */
export async function reclipWikiPage(doc: Doc, wikiBase: string): Promise<Doc> {
  const { content, sourceUrl } = await clipContent(doc.sourceKey!, wikiBase);
  const saved = await api.wsSaveDoc({ id: doc.id, kind: doc.kind, title: doc.title, content, parentId: doc.parentId, tags: doc.tags, pinned: doc.pinned, sourceUrl });
  workspaceChanged();
  return saved;
}

/** Wiki 地址中记录的版本（`pageVersion=`）。 */
export function wikiVersionOf(url: string | null | undefined): number | null {
  const m = url?.match(/[?&]pageVersion=(\d+)/);
  return m ? Number(m[1]) : null;
}
