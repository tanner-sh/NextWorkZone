import { useEffect, useState } from "react";
import { ClipboardList, Plus, Trash2 } from "lucide-react";
import { errorMessage, type IssueSummary } from "../../api";
import { ErrorBox, Modal } from "../../components/common";
import { useContextMenu } from "../../components/ContextMenu";
import { toast } from "../../components/Toast";
import { deleteTemplate, fillTemplate, saveTemplate, TEMPLATE_VARIABLES, useTemplates, type JiraTemplate } from "../../lib/templates";

/** 评论框旁的“模板”按钮：插入评论模板、把当前内容存为模板、管理模板。 */
export function CommentTemplateButton({ issue, draft, onInsert }: { issue: IssueSummary; draft: string; onInsert: (text: string) => void }) {
  const templates = useTemplates();
  const menu = useContextMenu();
  const [saving, setSaving] = useState(false);
  const [managing, setManaging] = useState(false);
  const comments = templates.filter((t) => t.kind === "comment");
  return (
    <>
      <button
        type="button"
        className={`btn subtle${menu.target === "templates" ? " active" : ""}`}
        title="评论模板"
        onClick={(e) =>
          menu.openAt(
            e.currentTarget,
            [
              comments.length > 0 && { label: "插入模板", disabled: true },
              ...comments.map((t) => ({ label: t.name, onSelect: () => onInsert(fillTemplate(t.body, issue)) })),
              comments.length > 0 && "separator",
              { label: "把当前内容存为模板…", icon: <Plus size={14} />, disabled: !draft.trim(), onSelect: () => setSaving(true) },
              { label: "管理模板…", onSelect: () => setManaging(true) },
            ],
            "templates",
          )
        }
      >
        <ClipboardList size={14} />
        模板
      </button>
      {menu.menu}
      {saving && <SaveTemplateDialog template={{ kind: "comment", body: draft }} onClose={() => setSaving(false)} />}
      {managing && <ManageTemplatesDialog onClose={() => setManaging(false)} />}
    </>
  );
}

/** 给模板起名并保存。 */
export function SaveTemplateDialog({ template, onClose }: { template: Omit<JiraTemplate, "id" | "name">; onClose: () => void }) {
  const [name, setName] = useState(template.transition ?? "");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const fieldCount = Object.keys(template.values ?? {}).length;
  const save = async () => {
    if (!name.trim()) return;
    setBusy(true);
    setError(null);
    try {
      await saveTemplate({ ...template, name: name.trim() });
      toast(`已保存模板“${name.trim()}”`);
      onClose();
    } catch (e) {
      setError(errorMessage(e));
      setBusy(false);
    }
  };
  return (
    <Modal
      title={template.kind === "transition" ? "保存流转模板" : "保存评论模板"}
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            取消
          </button>
          <button className="btn primary" disabled={!name.trim() || busy} onClick={save}>
            保存
          </button>
        </>
      }
    >
      <label className="form-field">
        <span>名称</span>
        <input value={name} placeholder="例如：已修复请验证" onChange={(e) => setName(e.target.value)} onKeyDown={(e) => e.key === "Enter" && !e.nativeEvent.isComposing && void save()} />
      </label>
      {template.kind === "transition" ? (
        <p className="muted small">
          保存「{template.transition}」流转时填写的 {fieldCount} 个字段{template.body.trim() ? "和评论" : ""}。之后在问题详情或右键菜单中选择这个模板，会打开流转对话框并预先填好，确认后提交。
        </p>
      ) : (
        <p className="muted small">评论框的“模板”按钮中可以插入。</p>
      )}
      <p className="muted small">内容中可以使用变量：{TEMPLATE_VARIABLES.map((v) => `${v.name} ${v.label}`).join("、")}。</p>
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}

/** 管理模板：修改名称和内容、删除。 */
export function ManageTemplatesDialog({ onClose }: { onClose: () => void }) {
  const templates = useTemplates();
  return (
    <Modal
      title="Jira 模板"
      wide
      onClose={onClose}
      footer={
        <button className="btn primary" onClick={onClose}>
          完成
        </button>
      }
    >
      <p className="muted small">
        评论模板在评论框的“模板”按钮中插入；流转模板在流转对话框中保存，之后可从问题详情、右键菜单一键打开。模板随工作空间同步到其他设备。可用变量：
        {TEMPLATE_VARIABLES.map((v) => `${v.name} ${v.label}`).join("、")}。
      </p>
      {templates.length === 0 && <p className="muted">还没有模板</p>}
      <ul className="template-list">
        {templates.map((t) => (
          <TemplateRow key={t.id} template={t} />
        ))}
      </ul>
    </Modal>
  );
}

function TemplateRow({ template }: { template: JiraTemplate }) {
  const [name, setName] = useState(template.name);
  const [body, setBody] = useState(template.body);
  const [confirming, setConfirming] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    setName(template.name);
    setBody(template.body);
  }, [template]);
  const dirty = name !== template.name || body !== template.body;
  const run = async (action: () => Promise<void>) => {
    setError(null);
    try {
      await action();
    } catch (e) {
      setError(errorMessage(e));
    }
  };
  return (
    <li>
      <div className="row-actions">
        <input className="grow" value={name} onChange={(e) => setName(e.target.value)} aria-label="模板名称" />
        <span className="pill nowrap">{template.kind === "transition" ? `流转：${template.transition}` : "评论"}</span>
        {dirty && (
          <button className="btn primary small-btn" disabled={!name.trim()} onClick={() => run(() => saveTemplate({ ...template, name: name.trim(), body }))}>
            保存
          </button>
        )}
        {confirming ? (
          <span className="inline-confirm">
            <button className="btn danger small-btn" onClick={() => run(() => deleteTemplate(template.id))}>
              删除
            </button>
            <button className="btn small-btn" onClick={() => setConfirming(false)}>
              取消
            </button>
          </span>
        ) : (
          <button className="btn subtle icon" title="删除" onClick={() => setConfirming(true)}>
            <Trash2 size={14} />
          </button>
        )}
      </div>
      <textarea rows={3} value={body} placeholder={template.kind === "transition" ? "流转时的评论（可选）" : "评论内容（wiki 标记）"} onChange={(e) => setBody(e.target.value)} />
      {template.kind === "transition" && Object.keys(template.values ?? {}).length > 0 && <p className="muted small">另含 {Object.keys(template.values!).length} 个字段值（重新保存流转模板可更新）</p>}
      {error && <ErrorBox message={error} />}
    </li>
  );
}
