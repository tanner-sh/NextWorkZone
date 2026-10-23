import { useEffect, useState } from "react";
import { api, errorMessage, type DocSummary, type WikiTemplate } from "../../api";
import { ErrorBox, Modal } from "../../components/common";
import { toast } from "../../components/Toast";
import { markdownToStorage } from "../workspace/editor/convert";

/** 开始编写新页面所需的信息。 */
export interface NewPageRequest {
  space: string;
  parent: string | null;
  parentTitle: string | null;
  title: string;
  /** Confluence 模板 id */
  template: string | null;
  /** 由知识库页面转换来的 storage */
  storage: string | null;
}

type Source = { kind: "blank" } | { kind: "template"; id: string } | { kind: "kb"; id: string };

/** 新建 Wiki 页面：填写标题，选择从空白页、Confluence 模板或知识库页面开始，然后进入编辑器（保存时才创建）。 */
export function NewPageDialog({ space, parent, onClose, onStart }: { space: string; parent: string | null; onClose: () => void; onStart: (request: NewPageRequest) => void }) {
  const [title, setTitle] = useState("");
  const [source, setSource] = useState<Source>({ kind: "blank" });
  const [templates, setTemplates] = useState<WikiTemplate[] | null>(null);
  const [kbPages, setKbPages] = useState<DocSummary[]>([]);
  const [parentTitle, setParentTitle] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    api.wikiTemplates(space).then(setTemplates, () => setTemplates([]));
    api.wsDocs("page").then(setKbPages, () => {});
    if (parent) api.wikiPageVersion(parent).then((p) => setParentTitle(p.title), () => {});
  }, [space, parent]);

  const start = async () => {
    setBusy(true);
    setError(null);
    try {
      let storage: string | null = null;
      if (source.kind === "kb") {
        const doc = await api.wsDoc(source.id);
        const converted = markdownToStorage(doc?.content ?? "");
        if (converted.assets.length > 0) toast("知识库页面中的图片不会带过去，可以在网页上补充");
        storage = converted.storage;
      }
      onStart({ space, parent, parentTitle, title: title.trim(), template: source.kind === "template" ? source.id : null, storage });
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const value = source.kind === "blank" ? "blank" : `${source.kind}:${source.id}`;
  return (
    <Modal
      title="新建 Wiki 页面"
      onClose={onClose}
      footer={
        <>
          <button className="btn" onClick={onClose}>
            取消
          </button>
          <button className="btn primary" disabled={busy || !title.trim()} onClick={start}>
            开始编写
          </button>
        </>
      }
    >
      <p className="muted small">
        位置：{space} 空间{parent ? `「${parentTitle ?? "…"}」下` : "顶层"}。编写完成并确认保存后才会在 Wiki 上创建。
      </p>
      <label className="form-field">
        <span>标题</span>
        <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="页面标题" onKeyDown={(e) => e.key === "Enter" && title.trim() && void start()} />
      </label>
      <label className="form-field">
        <span>内容</span>
        <select
          value={value}
          onChange={(e) => {
            const v = e.target.value;
            if (v === "blank") setSource({ kind: "blank" });
            else {
              const [kind, id] = [v.slice(0, v.indexOf(":")), v.slice(v.indexOf(":") + 1)];
              setSource({ kind: kind as "template" | "kb", id });
            }
          }}
        >
          <option value="blank">空白页面</option>
          {templates && templates.length > 0 && (
            <optgroup label="Confluence 模板">
              {templates.map((t) => (
                <option key={t.id} value={`template:${t.id}`}>
                  {t.name}
                  {t.spaceKey ? `（${t.spaceKey}）` : ""}
                </option>
              ))}
            </optgroup>
          )}
          {kbPages.length > 0 && (
            <optgroup label="从知识库页面">
              {kbPages.map((p) => (
                <option key={p.id} value={`kb:${p.id}`}>
                  {p.title || "无标题"}
                </option>
              ))}
            </optgroup>
          )}
        </select>
      </label>
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}
