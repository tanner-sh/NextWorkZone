import { useCallback, useEffect, useMemo, useState } from "react";
import { openUrl } from "@tauri-apps/plugin-opener";
import { api, errorMessage, type Draft, type DraftGroup, type OutlineItem, type WeeklyView } from "../../api";
import { CalendarPlus, ExternalLink, History, RefreshCw, Save, Sparkles } from "lucide-react";
import { ErrorBox, Modal, NotConfigured, Skeleton } from "../../components/common";
import { formatTime } from "../../lib/format";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { OutlineEditor, withIds, withoutIds, type EditorItem } from "./OutlineEditor";
import { diffOutline, sameOutline } from "./outlineDiff";
import { mergeInto, presence } from "./mergeDraft";
import { toast } from "../../components/Toast";

/** 未保存的编辑内容暂存在本地，防止误关窗口丢失。 */
const draftKey = (pageId: string, section: string) => `nextworkzone.weekly.${pageId}.${section}`;

interface LocalDraft {
  content: OutlineItem[];
  risk: OutlineItem[];
}

function readLocalDraft(key: string): LocalDraft | null {
  try {
    const raw = localStorage.getItem(key);
    return raw ? (JSON.parse(raw) as LocalDraft) : null;
  } catch {
    return null;
  }
}

function writeLocalDraft(key: string, draft: LocalDraft | null) {
  try {
    if (draft) localStorage.setItem(key, JSON.stringify(draft));
    else localStorage.removeItem(key);
  } catch {
    // 本地存储不可用时只是失去暂存功能
  }
}

export function WeeklyPage() {
  const { isReady, settings } = useSettings();
  const { navigate } = useNav();
  const [view, setView] = useState<WeeklyView | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(false);
  const [content, setContent] = useState<EditorItem[]>([]);
  const [risk, setRisk] = useState<EditorItem[]>([]);
  const [restored, setRestored] = useState(false);
  const [notice, setNotice] = useState<string | null>(null);
  const [confirmSave, setConfirmSave] = useState(false);
  const [confirmCreate, setConfirmCreate] = useState(false);
  const [busy, setBusy] = useState(false);
  const [actionError, setActionError] = useState<string | null>(null);

  const apply = useCallback((next: WeeklyView) => {
    setView(next);
    const entry = next.entry;
    if (!entry) {
      setContent([]);
      setRisk([]);
      return;
    }
    const local = readLocalDraft(draftKey(next.pageId, entry.sectionTitle));
    const useLocal = local !== null && (!sameOutline(local.content, entry.content) || !sameOutline(local.risk, entry.risk));
    setContent(withIds(useLocal ? local.content : entry.content));
    setRisk(withIds(useLocal ? local.risk : entry.risk));
    setRestored(useLocal);
  }, []);

  const load = useCallback(
    async (section: string | null = null) => {
      setLoading(true);
      setError(null);
      try {
        apply(await api.weeklyLoad(section));
      } catch (e) {
        setError(errorMessage(e));
      } finally {
        setLoading(false);
      }
    },
    [apply],
  );

  const configured = isReady("confluence") && Boolean(settings?.weeklyPageId);
  useEffect(() => {
    if (configured) void load();
  }, [configured, load]);

  const entry = view?.entry ?? null;
  const editedContent = useMemo(() => withoutIds(content), [content]);
  const editedRisk = useMemo(() => withoutIds(risk), [risk]);
  const dirty = entry !== null && (!sameOutline(editedContent, entry.content) || !sameOutline(editedRisk, entry.risk));

  // 编辑内容变化时暂存到本地
  useEffect(() => {
    if (!view || !entry) return;
    writeLocalDraft(draftKey(view.pageId, entry.sectionTitle), dirty ? { content: editedContent, risk: editedRisk } : null);
  }, [view, entry, dirty, editedContent, editedRisk]);

  if (!configured) {
    return (
      <section className="page">
        <header className="page-header">
          <h1>周报</h1>
        </header>
        <NotConfigured label="Wiki 或周报页面" onOpenSettings={() => navigate({ page: "settings" })} />
      </section>
    );
  }
  if (error) {
    return (
      <section className="page">
        <ErrorBox message={error} onRetry={() => load(entry?.sectionTitle ?? null)} />
      </section>
    );
  }
  if (!view)
    return (
      <section className="page">
        <Skeleton lines={2} height={22} />
        <Skeleton lines={8} />
      </section>
    );

  const save = async () => {
    if (!entry) return;
    setBusy(true);
    setActionError(null);
    try {
      const result = await api.weeklySave({
        section: entry.sectionTitle,
        contentRaw: entry.contentRaw,
        riskRaw: entry.riskRaw,
        content: editedContent,
        risk: editedRisk,
      });
      writeLocalDraft(draftKey(view.pageId, entry.sectionTitle), null);
      setConfirmSave(false);
      setNotice(result.changed ? `已保存到 Wiki（版本 ${result.version}）` : "内容没有变化，无需保存");
      await load(entry.sectionTitle);
    } catch (e) {
      setActionError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const createWeek = async () => {
    setBusy(true);
    setActionError(null);
    try {
      apply(await api.weeklyCreateWeek());
      setConfirmCreate(false);
      setNotice(`已新建 ${view.currentWeekTitle} 小节`);
    } catch (e) {
      setActionError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const switchSection = (title: string) => {
    if (dirty && !window.confirm("当前小节有未保存的修改（已暂存在本地），确定切换吗？")) return;
    setNotice(null);
    void load(title);
  };

  /** 并入草稿条目：放到同名分组下，已有的同一条只更新进度 */
  const insertDraft = (group: string | null, texts: string[]) => {
    const result = mergeInto(content, group, texts);
    setContent(result.next);
    const parts = [result.added > 0 && `插入 ${result.added} 条`, result.updated > 0 && `更新 ${result.updated} 条的进度`].filter(Boolean);
    toast(parts.length > 0 ? `已${parts.join("，")}` : "这些条目已在周报中");
  };

  return (
    <div className="weekly">
      <section className="page">
        <header className="page-header">
          <div>
            <h1>周报</h1>
            <p className="muted small">
              <button className="link" onClick={() => openUrl(view.pageUrl)}>
                {view.pageTitle} <ExternalLink size={11} />
              </button>{" "}
              · 版本 {view.version} · {view.modifiedBy} 于 {formatTime(view.modifiedAt)} 更新
            </p>
          </div>
          <div className="actions">
            <button className="btn" onClick={() => load(entry?.sectionTitle ?? null)} disabled={loading}>
              <RefreshCw size={14} className={loading ? "spin" : ""} />
              刷新
            </button>
            <button className="btn primary" disabled={!dirty || busy} onClick={() => setConfirmSave(true)}>
              <Save size={14} />
              预览并保存
            </button>
          </div>
        </header>

        {!view.currentWeekExists && (
          <div className="notice warn">
            <CalendarPlus size={15} />
            <span>本周（{view.currentWeekTitle}）的小节还没有创建。如果团队约定由他人创建，可以稍后刷新。</span>
            <span className="spacer" />
            <button className="btn" onClick={() => setConfirmCreate(true)}>
              按上周模板新建
            </button>
          </div>
        )}
        {notice && <p className="notice ok">{notice}</p>}

        <div className="segmented sections">
          {view.sections.map((s) => (
            <button key={s.title} className={entry?.sectionTitle === s.title ? "active" : ""} onClick={() => switchSection(s.title)}>
              {s.title}
              {s.coversToday && <span className="tag">本周</span>}
            </button>
          ))}
        </div>

        {entry && !entry.rowFound && (
          <div className="notice error">
            在「{entry.sectionTitle}」中没有找到第一列为「{view.personName}」的行。请确认你已被加入表格，或在设置中修改“我的名字”。
          </div>
        )}

        {entry?.rowFound && (
          <>
            {restored && <p className="notice warn">已恢复上次未保存的编辑内容。</p>}
            {entry.lossy && <p className="notice warn">原内容包含加粗、颜色等格式。只要修改了这一栏，保存后格式会变成纯文本列表；没修改的栏目保持原样。</p>}
            <div className="card">
              <div className="card-title">
                <h2>周报内容</h2>
                <span className="muted small">回车新增 · Tab 缩进 · Shift+Tab 取消缩进 · 可粘贴多行文本</span>
              </div>
              <OutlineEditor items={content} onChange={setContent} placeholder="点击开始填写，例如：客户或产品名称" />
            </div>
            <div className="card">
              <h2>风险事项</h2>
              <OutlineEditor items={risk} onChange={setRisk} placeholder="无风险可留空" />
            </div>
          </>
        )}
      </section>

      {entry?.rowFound && <DraftPanel section={entry.sectionTitle} content={content} onInsert={insertDraft} />}

      {confirmSave && entry && (
        <Modal
          title={`保存「${entry.sectionTitle}」的周报`}
          onClose={() => setConfirmSave(false)}
          footer={
            <>
              <button className="btn" onClick={() => setConfirmSave(false)}>
                取消
              </button>
              <button className="btn primary" disabled={busy} onClick={save}>
                {busy ? "保存中…" : "确认保存到 Wiki"}
              </button>
            </>
          }
        >
          <p className="muted small">只会修改你自己那一行；保存时会基于页面最新版本改写，不会覆盖他人的内容。</p>
          <DiffBlock title="周报内容" before={entry.content} after={editedContent} />
          <DiffBlock title="风险事项" before={entry.risk} after={editedRisk} />
          {actionError && <ErrorBox message={actionError} />}
        </Modal>
      )}

      {confirmCreate && (
        <Modal
          title={`新建 ${view.currentWeekTitle} 小节`}
          onClose={() => setConfirmCreate(false)}
          footer={
            <>
              <button className="btn" onClick={() => setConfirmCreate(false)}>
                取消
              </button>
              <button className="btn primary" disabled={busy} onClick={createWeek}>
                {busy ? "创建中…" : "确认新建"}
              </button>
            </>
          }
        >
          <p>将在页面最上方插入「{view.currentWeekTitle}」小节：</p>
          <ul>
            <li>复制「{view.sections[0]?.title}」的结构（说明文字、表头、人员名单）</li>
            <li>清空所有表格中填写的内容，人员名单保留</li>
            <li>这是对共享页面的修改，如果团队约定由他人创建，请先确认</li>
          </ul>
          {actionError && <ErrorBox message={actionError} />}
        </Modal>
      )}
    </div>
  );
}

function DiffBlock({ title, before, after }: { title: string; before: OutlineItem[]; after: OutlineItem[] }) {
  const lines = diffOutline(before, after);
  const changed = lines.some((l) => l.kind !== "same");
  return (
    <div className="diff-block">
      <h3>
        {title} {!changed && <span className="muted small">（无变化）</span>}
      </h3>
      {changed && (
        <ul className="outline-diff">
          {lines.map((l, i) => (
            <li key={i} className={l.kind} style={{ paddingLeft: 12 + l.level * 20 }}>
              <span className="diff-mark">{l.kind === "add" ? "+" : l.kind === "del" ? "−" : " "}</span>
              {l.text}
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

const SOURCE_LABELS: Record<string, string> = { jira: "Jira", worklog: "工作日志", gitlab: "GitLab", wiki: "Wiki", todo: "待办", daily: "日记" };

/** 作为周报条目的分组（问题、代码、工作日志）；其余（Wiki、待办、日记）是参考，单条插入时不加分组标题。 */
const isWorkGroup = (g: DraftGroup) => g.source === "jira" || g.source === "gitlab" || g.source === "worklog";

function DraftPanel({ section, content, onInsert }: { section: string; content: EditorItem[]; onInsert: (group: string | null, texts: string[]) => void }) {
  const [draft, setDraft] = useState<Draft | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => setDraft(null), [section]);

  const generate = async () => {
    setLoading(true);
    setError(null);
    try {
      setDraft(await api.weeklyDraft(section));
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setLoading(false);
    }
  };

  const insertAll = () => {
    for (const g of draft?.groups.filter(isWorkGroup) ?? []) onInsert(g.title, g.items.map((i) => i.text));
  };
  const pending = draft?.carryOver.filter((c) => !c.thisWeek) ?? [];
  const progressed = draft?.carryOver.filter((c) => c.thisWeek) ?? [];

  return (
    <aside className="draft-panel">
      <div className="card-title">
        <h2>
          <Sparkles size={16} className="muted" />
          草稿
        </h2>
        <span className="spacer" />
        {draft && draft.groups.some(isWorkGroup) && (
          <button className="btn subtle" onClick={insertAll} title="插入全部问题和代码条目；已在周报中的只更新进度">
            全部插入
          </button>
        )}
        <button className="btn" onClick={generate} disabled={loading}>
          {loading ? "生成中…" : draft ? "重新生成" : "生成草稿"}
        </button>
      </div>
      <p className="muted small">按“一件事”整理这一周的工作：每个 Jira 问题一条，提到它的推送、合并请求和完成的待办作为依据；分组和进度写法沿用往周周报，并和上周对比。插入时放到同名分组下，已有的条目只更新进度。</p>
      {error && <ErrorBox message={error} />}
      {draft && (
        <>
          <p className="muted small">
            范围：{draft.from} 至 {draft.to}
          </p>
          {draft.notes.map((n) => (
            <p key={n} className="notice warn small">
              {n}
            </p>
          ))}
          {draft.carryOver.length > 0 && (
            <div className="draft-group carry-over">
              <div className="draft-group-title">
                <History size={14} className="muted" />
                <strong className="ellipsis">上周（{draft.lastWeekTitle}）未完成 {draft.carryOver.length} 项</strong>
              </div>
              <ul>
                {pending.map((c) => {
                  const text = c.progress ? `${c.text}${draft.separator}${c.progress}` : c.text;
                  const state = presence(content, text);
                  return (
                    <li key={`p-${c.group}-${c.text}`}>
                      <button className="draft-item" onClick={() => onInsert(c.group || null, [text])} title="沿用到本周，插入后再修改进度">
                        <span className="draft-item-text">{c.text}</span>
                        <span className="draft-item-meta">
                          {c.progress && <span className="draft-chip">上周 {c.progress}</span>}
                          <span className="warn-text">本周没有记录</span>
                          {state !== "none" && <span className="muted">· 已在周报中</span>}
                        </span>
                      </button>
                    </li>
                  );
                })}
                {progressed.map((c) => (
                  <li key={`d-${c.group}-${c.text}`} className="draft-item static">
                    <span className="draft-item-text">{c.text}</span>
                    <span className="draft-item-meta">
                      {c.progress && <span className="draft-chip">上周 {c.progress}</span>}
                      <span className="ok-text">本周：{c.thisWeek}</span>
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          )}
          {draft.groups.length === 0 && <p className="muted">这一周没有找到相关记录。</p>}
          {draft.groups.map((g) => (
            <div className="draft-group" key={`${g.source}-${g.title}`}>
              <div className="draft-group-title">
                <span className={`source source-${g.source}`}>{SOURCE_LABELS[g.source] ?? g.source}</span>
                <strong className="ellipsis">{g.title}</strong>
                <button className="btn subtle" onClick={() => onInsert(g.title, g.items.map((i) => i.text))}>
                  插入
                </button>
              </div>
              <ul>
                {g.items.map((item) => {
                  const state = presence(content, item.text);
                  return (
                    <li key={item.text}>
                      <button
                        className={`draft-item${state === "same" ? " present" : ""}`}
                        onClick={() => onInsert(isWorkGroup(g) ? g.title : null, [item.text])}
                        title={state === "changed" ? "周报中已有这一条，点击更新进度" : "插入这一条"}
                      >
                        <span className="draft-item-text">{item.text}</span>
                        {(item.evidence.length > 0 || item.lastWeek || item.key || state !== "none") && (
                          <span className="draft-item-meta">
                            {item.key && <span className="issue-key">{item.key}</span>}
                            {item.lastWeek && <span className="draft-chip">上周 {item.lastWeek}</span>}
                            {state === "same" && <span className="muted">已在周报中</span>}
                            {state === "changed" && <span className="accent-text">周报中进度不同，点击更新</span>}
                            {item.evidence.length > 0 && <span className="muted ellipsis">{item.evidence.join(" · ")}</span>}
                          </span>
                        )}
                      </button>
                    </li>
                  );
                })}
              </ul>
            </div>
          ))}
        </>
      )}
    </aside>
  );
}
