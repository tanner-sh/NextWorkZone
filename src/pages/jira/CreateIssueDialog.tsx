import { useEffect, useMemo, useRef, useState } from "react";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { Paperclip, X } from "lucide-react";
import { api, errorMessage, type CreateProject, type FieldMeta, type IssueRef } from "../../api";
import { ErrorBox, Modal, Skeleton, SysImg } from "../../components/common";
import { referencedImages, type PendingImage } from "./wiki/WikiEditor";
import { explainError, FieldList, initialValues, isEmpty, missingRequired, Picker, toPayload, unsupportedRequired, UnsupportedNotice, type Values } from "./fieldForm";

const LAST_CHOICE_KEY = "nextworkzone.jira.lastCreate";

/** 记住上次创建时选择的项目和问题类型。 */
function lastChoice(): { project: string; issueType: string } | null {
  try {
    return JSON.parse(localStorage.getItem(LAST_CHOICE_KEY) ?? "null");
  } catch {
    return null;
  }
}

function saveChoice(project: string, issueType: string) {
  try {
    localStorage.setItem(LAST_CHOICE_KEY, JSON.stringify({ project, issueType }));
  } catch {
    // 本地存储不可用时不记忆
  }
}

/**
 * 新建问题。字段随所选项目和问题类型的创建界面动态生成。
 * 传入 `parent` 时创建该问题的子任务：项目固定，只能选择子任务类型。
 */
export function CreateIssueDialog(props: {
  parent?: IssueRef;
  /** 预先填好的概要和描述（例如从待办、笔记创建） */
  initial?: { summary: string; description: string };
  onClose: () => void;
  onCreated: (key: string, warning: string | null) => void;
}) {
  const { parent, initial } = props;
  const [projects, setProjects] = useState<CreateProject[] | null>(null);
  const [projectsError, setProjectsError] = useState<string | null>(null);
  const [projectKey, setProjectKey] = useState<string | null>(parent ? parent.key.replace(/-\d+$/, "") : (lastChoice()?.project ?? null));
  const [issueTypeId, setIssueTypeId] = useState<string | null>(null);
  const [fields, setFields] = useState<FieldMeta[] | null>(null);
  const [fieldsError, setFieldsError] = useState<string | null>(null);
  const [values, setValues] = useState<Values>({});
  const [files, setFiles] = useState<string[]>([]);
  const [images, setImages] = useState<PendingImage[]>([]);
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // 切换问题类型时保留已填写的内容
  const valuesRef = useRef(values);
  valuesRef.current = values;

  useEffect(() => {
    let cancelled = false;
    api.jiraCachedCreateProjects().then((cached) => !cancelled && cached && setProjects((p) => p ?? cached), () => {});
    api.jiraCreateProjects().then(
      (fresh) => !cancelled && setProjects(fresh),
      (e) => !cancelled && setProjectsError(errorMessage(e)),
    );
    return () => {
      cancelled = true;
    };
  }, []);

  const project = projects?.find((p) => p.key === projectKey) ?? null;
  const issueTypes = useMemo(() => project?.issueTypes.filter((t) => t.subtask === Boolean(parent)) ?? [], [project, parent]);

  // 项目变化后选择问题类型：优先沿用上次的类型
  useEffect(() => {
    if (issueTypes.length === 0) return;
    setIssueTypeId((current) => {
      if (current && issueTypes.some((t) => t.id === current)) return current;
      const last = lastChoice()?.issueType;
      return issueTypes.find((t) => t.id === last)?.id ?? issueTypes[0].id;
    });
  }, [issueTypes]);

  useEffect(() => {
    if (!projectKey || !issueTypeId) return;
    let cancelled = false;
    setFields(null);
    setFieldsError(null);
    api.jiraCreateFields(projectKey, issueTypeId).then(
      (meta) => {
        if (cancelled) return;
        const previous = valuesRef.current;
        const next = initialValues(meta);
        for (const f of meta) {
          if (!isEmpty(previous[f.key])) next[f.key] = previous[f.key];
        }
        if (parent && meta.some((f) => f.key === "parent")) next.parent = { key: parent.key, summary: parent.summary };
        if (initial) {
          if (isEmpty(next.summary) && meta.some((f) => f.key === "summary")) next.summary = initial.summary;
          if (isEmpty(next.description) && initial.description && meta.some((f) => f.key === "description")) next.description = initial.description;
        }
        setFields(meta);
        setValues(next);
      },
      (e) => !cancelled && setFieldsError(errorMessage(e)),
    );
    return () => {
      cancelled = true;
    };
    // initial 只在打开时用一次，不随之重新加载
  }, [projectKey, issueTypeId, parent]);

  const missing = fields ? missingRequired(fields, values) : [];
  const blocked = fields ? unsupportedRequired(fields).length > 0 : false;
  const dirty = Object.entries(values).some(([key, v]) => key !== "parent" && !isEmpty(v)) || files.length > 0;

  const submit = async () => {
    if (!fields || !projectKey || !issueTypeId) return;
    setSubmitting(true);
    setError(null);
    try {
      const fieldValues = toPayload(fields, values);
      const payload = { ...fieldValues, project: { key: projectKey }, issuetype: { id: issueTypeId } };
      // 正文中粘贴的图片随附件一起在创建后上传
      const pasted = referencedImages(images, Object.values(fieldValues).filter((v): v is string => typeof v === "string")).map((img) => img.path);
      const created = await api.jiraCreateIssue(payload, [...files, ...pasted]);
      saveChoice(projectKey, issueTypeId);
      props.onCreated(created.key, created.attachmentError ? `附件上传失败：${created.attachmentError}` : null);
    } catch (e) {
      setError(explainError(errorMessage(e), fields));
      setSubmitting(false);
    }
  };

  const pickFiles = async () => {
    const selected = await openDialog({ multiple: true, directory: false });
    if (selected) setFiles((old) => [...old, ...(Array.isArray(selected) ? selected : [selected]).filter((p) => !old.includes(p))]);
  };

  return (
    <Modal
      wide
      dirty={dirty}
      title={parent ? `为 ${parent.key} 新建子任务` : "新建问题"}
      onClose={props.onClose}
      footer={
        <>
          {missing.length > 0 && <span className="small error-text grow">请填写：{missing.map((f) => f.name).join("、")}</span>}
          <button className="btn" onClick={props.onClose}>
            取消
          </button>
          <button className="btn primary" disabled={!fields || submitting || missing.length > 0 || blocked} onClick={submit}>
            {submitting ? "创建中…" : "创建"}
          </button>
        </>
      }
    >
      {projectsError && !projects && <ErrorBox message={projectsError} />}
      <div className="form-grid">
        <div className="form-field">
          <span>
            项目<em className="required">*</em>
          </span>
          {parent ? (
            <input value={project ? `${project.name}（${project.key}）` : (projectKey ?? "")} disabled />
          ) : (
            <Picker<CreateProject>
              selected={project ? [project] : []}
              onChange={(list) => setProjectKey(list[0]?.key ?? null)}
              search={(q) => {
                const query = q.trim().toLowerCase();
                return (projects ?? []).filter((p) => `${p.key} ${p.name}`.toLowerCase().includes(query));
              }}
              label={(p) => `${p.name}（${p.key}）`}
              id={(p) => p.key}
              placeholder={projects ? "搜索项目名称或键" : "正在加载项目…"}
              searchOnFocus
            />
          )}
        </div>
        <div className="form-field">
          <span>
            问题类型<em className="required">*</em>
          </span>
          <div className="type-select">
            <SysImg service="jira" src={issueTypes.find((t) => t.id === issueTypeId)?.iconUrl} className="icon16" />
            <select value={issueTypeId ?? ""} disabled={issueTypes.length === 0} onChange={(e) => setIssueTypeId(e.target.value)}>
              {issueTypes.length === 0 && <option value="">{project ? "该项目没有可用的类型" : "请先选择项目"}</option>}
              {issueTypes.map((t) => (
                <option key={t.id} value={t.id}>
                  {t.name}
                </option>
              ))}
            </select>
          </div>
        </div>
      </div>

      {fieldsError && <ErrorBox message={fieldsError} />}
      {projectKey && issueTypeId && !fields && !fieldsError && <Skeleton lines={8} height={28} />}
      {fields && (
        <>
          <UnsupportedNotice fields={fields} action={<span>请在网页中创建此类问题。</span>} />
          <FieldList
            fields={fields}
            values={values}
            onChange={(key, value) => setValues((old) => ({ ...old, [key]: value }))}
            context={{ issueKey: null, projectKey, onImage: (img) => setImages((list) => [...list, img]) }}
          />
          {/* 附件在问题创建成功后再上传 */}
          <div className="form-field">
            <span>附件</span>
            <div className="file-list">
              {files.map((path) => (
                <span className="chip" key={path} title={path}>
                  {path.split(/[\\/]/).pop()}
                  <button type="button" onClick={() => setFiles((old) => old.filter((p) => p !== path))} aria-label="移除">
                    <X size={11} />
                  </button>
                </span>
              ))}
              <button type="button" className="btn" onClick={pickFiles}>
                <Paperclip size={14} />
                选择文件
              </button>
            </div>
          </div>
        </>
      )}
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}
