// 编辑器中识别 Jira 问题键：存在的问题加上状态样式和概要提示，Ctrl+点击打开。
// 正文保持纯文本（Markdown 里仍是 ABC-123），只做显示层的装饰。
import { Extension } from "@tiptap/core";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import { Decoration, DecorationSet, type EditorView } from "@tiptap/pm/view";
import type { Node as PmNode } from "@tiptap/pm/model";
import { api, type IssueSummary } from "../../../api";

const KEY_PATTERN = /(?<![A-Za-z0-9_-])([A-Z][A-Z0-9_]{1,19}-[1-9][0-9]{0,6})(?![A-Za-z0-9_])/g;

/** 已查询过的问题：存在时为问题信息，不存在为 null。 */
const known = new Map<string, IssueSummary | null>();
const pending = new Set<string>();
const views = new Set<EditorView>();
let timer: number | null = null;
let enabled = true;

export const issueRefsKey = new PluginKey<DecorationSet>("issueRefs");

/** 未配置 Jira 时不查询。 */
export function setIssueLookupEnabled(value: boolean) {
  enabled = value;
}

export function issueInfo(key: string): IssueSummary | null | undefined {
  return known.get(key);
}

function request(keys: string[]) {
  if (!enabled) return;
  let added = false;
  for (const key of keys) {
    if (!known.has(key) && !pending.has(key)) {
      pending.add(key);
      added = true;
    }
  }
  if (!added || timer) return;
  timer = window.setTimeout(() => {
    timer = null;
    void fetchPending();
  }, 300);
}

async function fetchPending() {
  const keys = [...pending].slice(0, 50);
  if (keys.length === 0) return;
  const record = (found: IssueSummary[]) => {
    for (const key of keys) known.set(key, found.find((i) => i.key === key) ?? null);
  };
  try {
    record((await api.jiraSearch(`key in (${keys.join(",")})`, 0, keys.length)).issues);
  } catch {
    // 有不存在的键时整个查询失败，改为逐个查询
    const found: IssueSummary[] = [];
    for (const key of keys) {
      const hit = await api.jiraPickIssues(key, null, false).catch(() => []);
      found.push(...hit.filter((i) => i.key === key));
    }
    record(found);
  }
  keys.forEach((k) => pending.delete(k));
  // 通知所有编辑器重新装饰
  for (const view of views) {
    if (!view.isDestroyed) view.dispatch(view.state.tr.setMeta(issueRefsKey, "refresh"));
  }
  if (pending.size > 0) void fetchPending();
}

function decorate(doc: PmNode): DecorationSet {
  const decorations: Decoration[] = [];
  const unknown: string[] = [];
  doc.descendants((node, pos) => {
    if (!node.isText || !node.text) return;
    // 代码里的不处理
    if (node.marks.some((m) => m.type.name === "code")) return;
    for (const match of node.text.matchAll(KEY_PATTERN)) {
      const key = match[1];
      const info = known.get(key);
      if (info === undefined) unknown.push(key);
      if (!info) continue;
      const from = pos + match.index!;
      decorations.push(
        Decoration.inline(from, from + key.length, {
          class: `issue-ref status-${info.status.category}`,
          "data-issue-key": key,
          "data-status": info.status.name,
          title: `${key} ${info.summary}\n${info.status.name} · Ctrl+点击打开`,
        }),
      );
    }
  });
  if (unknown.length > 0) request(unknown);
  return DecorationSet.create(doc, decorations);
}

export const IssueRefs = Extension.create({
  name: "issueRefs",
  addProseMirrorPlugins() {
    return [
      new Plugin<DecorationSet>({
        key: issueRefsKey,
        state: {
          init: (_, state) => decorate(state.doc),
          apply: (tr, old) => (tr.docChanged || tr.getMeta(issueRefsKey) ? decorate(tr.doc) : old.map(tr.mapping, tr.doc)),
        },
        props: {
          decorations: (state) => issueRefsKey.getState(state),
        },
        view: (view) => {
          views.add(view);
          return { destroy: () => views.delete(view) };
        },
      }),
    ];
  },
});
