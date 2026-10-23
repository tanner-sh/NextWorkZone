// 文档（笔记、日记、知识库页面）右键菜单的共用部分。
import { Copy, Pin, PinOff, Trash2 } from "lucide-react";
import { api, type Doc, type DocInput, type DocSummary } from "../../api";
import type { MenuEntry } from "../../components/ContextMenu";
import { guarded, toast } from "../../components/Toast";
import { copyText } from "../../lib/clipboard";
import { workspaceChanged } from "../../lib/workspace";

/** 保存时需要提交完整字段。 */
export function docInput(doc: Doc, patch: Partial<Doc> = {}): DocInput {
  const next = { ...doc, ...patch };
  return {
    id: next.id,
    kind: next.kind,
    title: next.title,
    content: next.content,
    parentId: next.parentId,
    tags: next.tags,
    pinned: next.pinned,
    sourceSystem: next.sourceSystem,
    sourceKey: next.sourceKey,
    sourceUrl: next.sourceUrl,
  };
}

export function pinItem(doc: Pick<DocSummary, "id" | "pinned">): MenuEntry {
  return {
    label: doc.pinned ? "取消置顶" : "置顶",
    icon: doc.pinned ? <PinOff size={14} /> : <Pin size={14} />,
    onSelect: guarded(async () => {
      const full = await api.wsDoc(doc.id);
      if (!full) return;
      await api.wsSaveDoc(docInput(full, { pinned: !full.pinned }));
      workspaceChanged();
    }),
  };
}

export function copyTitleItem(title: string): MenuEntry {
  return {
    label: "复制标题",
    icon: <Copy size={14} />,
    disabled: !title,
    onSelect: guarded(async () => {
      await copyText(title);
      toast("已复制");
    }),
  };
}

/** `beforeDelete` 在删除前调用，用于先关闭正在编辑的文档。 */
export function deleteItem(id: string, label: string, beforeDelete: () => void): MenuEntry {
  return {
    label,
    icon: <Trash2 size={14} />,
    danger: true,
    confirm: "再点一次确认删除",
    onSelect: guarded(async () => {
      beforeDelete();
      await api.wsDeleteDoc(id);
      workspaceChanged();
    }),
  };
}
