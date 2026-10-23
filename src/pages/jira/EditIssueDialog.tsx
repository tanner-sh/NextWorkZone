import { useEffect, useMemo, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { api, errorMessage, type FieldMeta, type IssueDetail } from "../../api";
import { ErrorBox, Modal, Skeleton } from "../../components/common";
import { useSettings } from "../../state/settings";
import { explainError, FieldList, initialValues, missingRequired, toPayload, unsupportedRequired, UnsupportedNotice, type Values } from "./fieldForm";
import { projectKeyOf } from "./jql";
import { referencedImages, type PendingImage } from "./wiki/WikiEditor";

/** 编辑问题：字段来自问题的编辑界面（editmeta），只提交改动过的字段。 */
export function EditIssueDialog(props: { issueKey: string; onClose: () => void; onDone: (issue: IssueDetail) => void }) {
  const { issueKey } = props;
  const baseUrl = useSettings().baseUrl("jira");
  const [fields, setFields] = useState<FieldMeta[] | null>(null);
  const [initial, setInitial] = useState<Values>({});
  const [values, setValues] = useState<Values>({});
  const [loadError, setLoadError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [images, setImages] = useState<PendingImage[]>([]);

  const load = async () => {
    setLoadError(null);
    try {
      const meta = await api.jiraEditFields(issueKey);
      setFields(meta);
      setInitial(initialValues(meta));
      setValues(initialValues(meta));
    } catch (e) {
      setLoadError(errorMessage(e));
    }
  };

  useEffect(() => {
    void load();
  }, [issueKey]);

  const changes = useMemo(() => (fields ? toPayload(fields, values, initial) : {}), [fields, values, initial]);
  const changedCount = Object.keys(changes).length;
  const missing = fields ? missingRequired(fields, values) : [];

  const save = async () => {
    if (!fields) return;
    if (changedCount === 0) {
      props.onClose();
      return;
    }
    setSaving(true);
    setError(null);
    try {
      // 先上传正文中引用的粘贴图片，保存后 !文件名! 才能显示
      const used = referencedImages(images, Object.values(changes).filter((v): v is string => typeof v === "string"));
      if (used.length > 0) await api.jiraUploadAttachments(issueKey, used.map((img) => img.path));
      props.onDone(await api.jiraUpdateIssue(issueKey, changes));
    } catch (e) {
      setError(explainError(errorMessage(e), fields));
      setSaving(false);
    }
  };

  return (
    <Modal
      wide
      dirty={changedCount > 0}
      title={`编辑 ${issueKey}`}
      onClose={props.onClose}
      footer={
        <>
          {changedCount > 0 && <span className="muted small grow">已修改 {changedCount} 个字段</span>}
          {missing.length > 0 && <span className="small error-text">请填写：{missing.map((f) => f.name).join("、")}</span>}
          <button className="btn" onClick={props.onClose}>
            取消
          </button>
          <button className="btn primary" disabled={!fields || saving || missing.length > 0} onClick={save}>
            {saving ? "保存中…" : "保存"}
          </button>
        </>
      }
    >
      {loadError && <ErrorBox message={loadError} onRetry={load} />}
      {!fields && !loadError && <Skeleton lines={10} height={28} />}
      {fields && (
        <>
          {/* 必填但无法编辑的字段并不妨碍修改其他字段，这里只做提示 */}
          {unsupportedRequired(fields).length > 0 && (
            <UnsupportedNotice
              fields={fields}
              action={
                <button className="link" onClick={() => openUrl(`${baseUrl}/browse/${issueKey}`)}>
                  如需修改请在网页中处理。
                </button>
              }
            />
          )}
          <FieldList
            fields={fields}
            values={values}
            onChange={(key, value) => setValues((old) => ({ ...old, [key]: value }))}
            context={{ issueKey, projectKey: projectKeyOf(issueKey), onImage: (img) => setImages((list) => [...list, img]) }}
          />
        </>
      )}
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}
