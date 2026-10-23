import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import { Pin, PinOff, Tag, Trash2, X } from "lucide-react";
import { api, errorMessage, type Doc } from "../../api";
import { ErrorBox, Skeleton } from "../../components/common";
import { useWorkspaceRefresh, weekdayOf, workspaceChanged } from "../../lib/workspace";
import { useNav } from "../../state/nav";
import { CreateIssueDialog } from "../jira/CreateIssueDialog";
import { Backlinks } from "./Backlinks";
import { docInput } from "./docMenu";
import { NoteEditor } from "./editor/NoteEditor";

interface Props {
  /** 文档 id；日记为 daily-YYYY-MM-DD（不存在时首次输入后创建） */
  docId: string;
  onSaved?: (doc: Doc) => void;
  onDeleted?: () => void;
  /** 标题下方的额外内容（知识库的来源、子页面等） */
  header?: (doc: Doc) => ReactNode;
  /** 标题栏右侧的额外操作 */
  actions?: (doc: Doc) => ReactNode;
  /** 正文下方的额外内容（日记的工作记录） */
  footer?: (doc: Doc) => ReactNode;
}

/** 文档编辑面板：标题、标签、正文编辑器、反向链接，修改自动保存。 */
export function DocPane({ docId, onSaved, onDeleted, header, actions, footer }: Props) {
  const { navigate } = useNav();
  const [doc, setDoc] = useState<Doc | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);
  const [confirmDelete, setConfirmDelete] = useState(false);
  const [issueDraft, setIssueDraft] = useState<{ summary: string; description: string; insert: (key: string) => void } | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const latest = useRef<Doc | null>(null);
  latest.current = doc;
  const titleTimer = useRef<number | null>(null);
  const saving = useRef<Promise<unknown>>(Promise.resolve());

  const load = useCallback(async () => {
    try {
      const day = docId.startsWith("daily-") ? docId.slice(6) : null;
      const loaded = day ? await api.wsDaily(day) : await api.wsDoc(docId);
      if (!loaded) {
        setError("文档不存在或已被删除");
        return;
      }
      setDoc(loaded);
      setError(null);
    } catch (e) {
      setError(errorMessage(e));
    }
  }, [docId]);
  useEffect(() => {
    void load();
  }, [load]);
  // 其他设备同步过来的修改：标题没在编辑时刷新
  useWorkspaceRefresh(() => {
    if (!titleTimer.current) void load();
  });

  const save = useCallback(
    (patch: Partial<Doc>) => {
      const current = latest.current;
      if (!current) return;
      const next = { ...current, ...patch };
      setDoc(next);
      latest.current = next;
      // 空日记不保存
      if (next.kind === "daily" && next.createdAt === 0 && !next.content.trim()) return;
      // 按顺序保存，避免较早的请求覆盖较新的内容
      saving.current = saving.current.then(async () => {
        try {
          const saved = await api.wsSaveDoc(docInput(next));
          // 保存期间又有新输入时只更新时间戳等字段，不覆盖正在编辑的内容
          setDoc((d) => (d ? { ...saved, title: d.title, content: d.content, tags: d.tags } : saved));
          setSaveError(null);
          onSaved?.(saved);
          workspaceChanged();
        } catch (e) {
          setSaveError(errorMessage(e));
        }
      });
    },
    [onSaved],
  );

  const remove = async () => {
    if (!doc) return;
    try {
      await api.wsDeleteDoc(doc.id);
      workspaceChanged();
      onDeleted?.();
    } catch (e) {
      setSaveError(errorMessage(e));
    }
  };

  if (error) return <div className="detail-body"><ErrorBox message={error} onRetry={load} /></div>;
  if (!doc) return <div className="detail-body"><Skeleton lines={8} /></div>;

  const isDaily = doc.kind === "daily";
  const exists = doc.createdAt !== 0;

  return (
    <div className="detail-body doc-pane">
      <header className="doc-header">
        {isDaily ? (
          <div className="daily-title">
            <h1>{doc.day}</h1>
            <span className="muted">{weekdayOf(doc.day!)}</span>
          </div>
        ) : (
          <input
            className="doc-title-input"
            value={doc.title}
            placeholder="无标题"
            onChange={(e) => {
              const title = e.target.value;
              setDoc({ ...doc, title });
              if (titleTimer.current) window.clearTimeout(titleTimer.current);
              titleTimer.current = window.setTimeout(() => {
                titleTimer.current = null;
                save({ title });
              }, 500);
            }}
          />
        )}
        <div className="doc-actions">
          {actions?.(doc)}
          {!isDaily && (
            <button className="btn subtle icon" title={doc.pinned ? "取消置顶" : "置顶"} onClick={() => save({ pinned: !doc.pinned })}>
              {doc.pinned ? <PinOff size={15} /> : <Pin size={15} />}
            </button>
          )}
          {exists &&
            (confirmDelete ? (
              <span className="inline-confirm">
                <button className="btn danger small-btn" onClick={remove}>
                  {doc.kind === "page" ? "删除（含子页面）" : "确认删除"}
                </button>
                <button className="btn small-btn" onClick={() => setConfirmDelete(false)}>
                  取消
                </button>
              </span>
            ) : (
              <button className="btn subtle icon" title="删除" onClick={() => setConfirmDelete(true)}>
                <Trash2 size={15} />
              </button>
            ))}
        </div>
      </header>

      {!isDaily && <TagsInput tags={doc.tags} onChange={(tags) => save({ tags })} />}
      {header?.(doc)}
      {notice && (
        <div className="notice ok">
          <span className="grow">{notice}</span>
          <button className="btn subtle icon" onClick={() => setNotice(null)} aria-label="关闭">
            <X size={13} />
          </button>
        </div>
      )}

      <NoteEditor
        key={doc.id}
        docId={doc.id}
        value={doc.content}
        onChange={(content) => save({ content })}
        placeholder={isDaily ? "今天做了什么、遇到什么问题、明天要做什么…" : undefined}
        onOpenDoc={(id) => openDoc(id)}
        onOpenIssue={(key) => navigate({ page: "jira", issueKey: key })}
        onCreateTodos={async (lines) => {
          try {
            for (const line of lines) {
              await api.wsSaveTodo({ title: line.replace(/^[-*]\s*(\[[ xX]\]\s*)?/, ""), refSystem: "doc", refKey: doc.id, refTitle: doc.title || doc.day });
            }
            workspaceChanged();
            setNotice(`已创建 ${lines.length} 条待办`);
          } catch (e) {
            setSaveError(errorMessage(e));
          }
        }}
        onCreateIssue={(text, insert) => {
          const [first, ...rest] = text.split("\n");
          setIssueDraft({ summary: first.trim(), description: rest.join("\n").trim(), insert });
        }}
      />
      {saveError && <ErrorBox message={`保存失败：${saveError}`} />}
      {footer?.(doc)}

      {exists && <Backlinks system="doc" itemKey={doc.id} title="引用了本文的内容" hideEmpty />}

      {issueDraft && (
        <CreateIssueDialog
          initial={{ summary: issueDraft.summary, description: issueDraft.description }}
          onClose={() => setIssueDraft(null)}
          onCreated={(key) => {
            issueDraft.insert(key);
            setIssueDraft(null);
            setNotice(`已创建 ${key}`);
          }}
        />
      )}
    </div>
  );

  function openDoc(id: string) {
    api.wsDoc(id).then((target) => {
      if (target) navigate({ page: target.kind === "page" ? "kb" : "notes", docId: target.id });
    }, () => {});
  }
}

function TagsInput({ tags, onChange }: { tags: string[]; onChange: (tags: string[]) => void }) {
  const [draft, setDraft] = useState("");
  const add = () => {
    const tag = draft.trim().replace(/^#/, "");
    if (tag && !tags.includes(tag)) onChange([...tags, tag]);
    setDraft("");
  };
  return (
    <div className="tags-input">
      <Tag size={13} className="muted" />
      {tags.map((t) => (
        <span className="chip" key={t}>
          {t}
          <button type="button" onClick={() => onChange(tags.filter((x) => x !== t))} aria-label={`移除标签 ${t}`}>
            <X size={11} />
          </button>
        </span>
      ))}
      <input
        value={draft}
        placeholder={tags.length ? "" : "添加标签"}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={add}
        onKeyDown={(e) => {
          if ((e.key === "Enter" || e.key === ",") && !e.nativeEvent.isComposing) {
            e.preventDefault();
            add();
          } else if (e.key === "Backspace" && !draft && tags.length) {
            onChange(tags.slice(0, -1));
          }
        }}
      />
    </div>
  );
}
