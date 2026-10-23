import { useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { api, errorMessage, type CommentVisibility, type IssueDetail, type IssueSummary, type Transition } from "../../api";
import { VisibilitySelect } from "./IssueActivity";
import { ErrorBox, Modal, StatusPill } from "../../components/common";
import { useSettings } from "../../state/settings";
import { fillTemplate, useTemplates, type JiraTemplate } from "../../lib/templates";
import { SaveTemplateDialog } from "./templates";
import { referencedImages, WikiEditor, type PendingImage } from "./wiki/WikiEditor";
import { explainError, FieldList, missingRequired, toPayload, unsupportedRequired, UnsupportedNotice, type Values } from "./fieldForm";

/** 模板中属于这次流转界面的字段值（工作流修改后可能有字段已不存在）。 */
function templateValues(template: JiraTemplate | undefined, transition: Transition): Values {
  const keys = new Set(transition.fields.map((f) => f.key));
  return Object.fromEntries(Object.entries(template?.values ?? {}).filter(([k]) => keys.has(k)));
}

/**
 * 状态流转对话框：根据流转界面上的字段动态生成表单。
 * `template` 为预先选择的流转模板；`issue` 用于替换模板中的变量。
 */
export function TransitionDialog(props: {
  issueKey: string;
  projectKey: string | null;
  transition: Transition;
  issue?: IssueSummary;
  template?: JiraTemplate;
  onClose: () => void;
  onDone: (issue: IssueDetail) => void;
}) {
  const { issueKey, transition } = props;
  const baseUrl = useSettings().baseUrl("jira");
  const fill = (body: string) => (props.issue ? fillTemplate(body, props.issue) : body);
  const [values, setValues] = useState<Values>(() => templateValues(props.template, transition));
  const [comment, setComment] = useState(() => fill(props.template?.body ?? ""));
  const [visibility, setVisibility] = useState<CommentVisibility | null>(null);
  const [applied, setApplied] = useState<string | null>(props.template?.id ?? null);
  const [savingTemplate, setSavingTemplate] = useState(false);
  const templates = useTemplates().filter((t) => t.kind === "transition" && t.transition === transition.name);
  const applyTemplate = (t: JiraTemplate) => {
    setValues(templateValues(t, transition));
    setComment(fill(t.body));
    setApplied(t.id);
  };
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [images, setImages] = useState<PendingImage[]>([]);
  const onImage = (img: PendingImage) => setImages((list) => [...list, img]);

  const blocked = unsupportedRequired(transition.fields).length > 0;
  const missing = missingRequired(transition.fields, values);

  const submit = async () => {
    setSubmitting(true);
    setError(null);
    try {
      const payload = toPayload(transition.fields, values);
      const used = referencedImages(images, [comment, ...Object.values(payload).filter((v): v is string => typeof v === "string")]);
      if (used.length > 0) await api.jiraUploadAttachments(issueKey, used.map((img) => img.path));
      const detail = await api.jiraTransition(issueKey, transition.id, payload, comment.trim() || null, visibility);
      props.onDone(detail);
    } catch (e) {
      setError(explainError(errorMessage(e), transition.fields));
      setSubmitting(false);
    }
  };

  return (
    <>
    <Modal
      title={`${issueKey} · ${transition.name}`}
      onClose={props.onClose}
      dirty={Boolean(comment.trim()) || Object.keys(values).length > 0}
      footer={
        <>
          <button className="btn subtle footer-start" onClick={() => setSavingTemplate(true)} title="保存这次填写的字段和评论，下次一键填好">
            存为模板
          </button>
          <button className="btn" onClick={props.onClose}>
            取消
          </button>
          <button className="btn primary" disabled={submitting || missing.length > 0 || blocked} onClick={submit}>
            {submitting ? "提交中…" : `确认${transition.name}`}
          </button>
        </>
      }
    >
      <p className="muted">
        流转后状态：<StatusPill status={transition.to} />
      </p>
      {templates.length > 0 && (
        <div className="template-chips">
          <span className="muted small">模板</span>
          {templates.map((t) => (
            <button key={t.id} type="button" className={`chip-btn${applied === t.id ? " on" : ""}`} onClick={() => applyTemplate(t)}>
              {t.name}
            </button>
          ))}
        </div>
      )}
      <UnsupportedNotice
        fields={transition.fields}
        action={
          <button className="link" onClick={() => openUrl(`${baseUrl}/browse/${issueKey}`)}>
            请在网页中处理。
          </button>
        }
      />
      <FieldList
        fields={transition.fields}
        values={values}
        onChange={(key, value) => setValues((old) => ({ ...old, [key]: value }))}
        context={{ issueKey, projectKey: props.projectKey, onImage }}
      />
      <div className="form-field">
        <span>评论（可选）</span>
        <WikiEditor value={comment} onChange={setComment} issueKey={issueKey} onImage={onImage} minHeight={80} footer={<VisibilitySelect issueKey={issueKey} value={visibility} onChange={setVisibility} />} />
      </div>
      {error && <ErrorBox message={error} />}
    </Modal>
    {savingTemplate && <SaveTemplateDialog template={{ kind: "transition", transition: transition.name, values, body: comment }} onClose={() => setSavingTemplate(false)} />}
    </>
  );
}
