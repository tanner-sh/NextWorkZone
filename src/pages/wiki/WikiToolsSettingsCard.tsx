import { useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { Bell, CheckSquare, Database, RefreshCw } from "lucide-react";
import { api, errorMessage, WIKI_INDEX_EVENT, type WikiIndexStatus, type WikiSpace, type WikiToolsSettings } from "../../api";
import { formatTime } from "../../lib/format";

/** 本机 Wiki 库的状态，同步过程中随进度更新。 */
function useWikiIndexStatus(): WikiIndexStatus | null {
  const [status, setStatus] = useState<WikiIndexStatus | null>(null);
  useEffect(() => {
    let alive = true;
    const refresh = () => api.wikiIndexStatus().then((s) => alive && setStatus(s), () => {});
    refresh();
    // 同步时每批都会发事件，合并成每秒最多刷新一次
    let timer: number | null = null;
    const unlisten = listen(WIKI_INDEX_EVENT, () => {
      if (timer === null) {
        timer = window.setTimeout(() => {
          timer = null;
          refresh();
        }, 1000);
      }
    });
    return () => {
      alive = false;
      if (timer !== null) window.clearTimeout(timer);
      void unlisten.then((fn) => fn());
    };
  }, []);
  return status;
}

/** 设置页中的 Wiki 增强功能：本机 Wiki 库、页面任务同步为待办、Wiki 动态。修改后立即生效。 */
export function WikiToolsSettingsCard() {
  const [settings, setSettings] = useState<WikiToolsSettings | null>(null);
  const [spaces, setSpaces] = useState<WikiSpace[]>([]);
  const [mutedDraft, setMutedDraft] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const status = useWikiIndexStatus();

  useEffect(() => {
    api.wikiToolsSettings().then((s) => {
      setSettings(s);
      setMutedDraft(s.mutedPages.join("\n"));
    }, (e) => setError(errorMessage(e)));
    api.wikiCachedSpaces().then((cached) => cached && setSpaces(cached), () => {});
    api.wikiSpaces().then(setSpaces, () => {});
  }, []);

  const update = async (patch: Partial<WikiToolsSettings>) => {
    if (!settings) return;
    setBusy(true);
    setError(null);
    try {
      const saved = await api.wikiSaveToolsSettings({ ...settings, ...patch });
      setSettings(saved);
      setMutedDraft(saved.mutedPages.join("\n"));
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  if (!settings) return error ? <p className="notice error">{error}</p> : null;
  const allSpaces = settings.indexSpaces.length === 0;
  const toggleSpace = (key: string) => {
    const list = settings.indexSpaces.includes(key) ? settings.indexSpaces.filter((k) => k !== key) : [...settings.indexSpaces, key];
    void update({ indexSpaces: list });
  };
  const muted = mutedDraft
    .split(/[\s,，]+/)
    .map((s) => s.match(/pageId=(\d+)/)?.[1] ?? s.trim())
    .filter(Boolean);

  return (
    <div className="card">
      <div className="service-head">
        <span className="service-icon">
          <Database size={16} />
        </span>
        <div>
          <h2>Wiki 本机库</h2>
          <p className="muted small">把页面的标题和正文同步到本机：搜索即时出结果、能搜到两个字的中文词；也用于在 Jira 问题中显示引用它的 Wiki 页面，以及找出分配给你的页面任务。只读取 Wiki，不做任何修改。</p>
        </div>
      </div>
      <label className="checkbox">
        <input type="checkbox" checked={settings.indexEnabled} disabled={busy} onChange={(e) => update({ indexEnabled: e.target.checked })} />
        启用本机 Wiki 库（每 10 分钟同步一次有变化的页面）
      </label>
      {settings.indexEnabled && (
        <>
          <div className="field">
            <span>状态</span>
            <div className="row-actions grow">
              <span className={`small grow ${status?.error ? "error-text" : "muted"}`}>
                {!status
                  ? "读取中…"
                  : status.running
                    ? `正在同步${status.progress ? `：${status.progress.done}/${status.progress.total}` : "…"} · 已有 ${status.count} 个页面`
                    : status.error
                      ? `同步失败：${status.error}`
                      : status.count > 0
                        ? `${status.count} 个页面 · ${status.spaces.length} 个空间${status.lastSync ? ` · ${formatTime(status.lastSync)} 同步` : ""}`
                        : "尚未同步"}
              </span>
              <button className="btn" disabled={status?.running} onClick={() => api.wikiIndexSync()}>
                <RefreshCw size={14} className={status?.running ? "spin" : ""} />
                立即同步
              </button>
              <button className="btn subtle" disabled={status?.running} onClick={() => api.wikiIndexRebuild().catch((e) => setError(errorMessage(e)))} title="清空本机数据后重新同步">
                重建
              </button>
            </div>
          </div>
          <div className="field">
            <span>范围</span>
            <div className="grow index-scope">
              <label className="checkbox">
                <input type="radio" checked={allSpaces} disabled={busy} onChange={() => update({ indexSpaces: [] })} />
                全部可见的空间
              </label>
              <label className="checkbox">
                <input type="radio" checked={!allSpaces} disabled={busy || spaces.length === 0} onChange={() => spaces[0] && update({ indexSpaces: [spaces[0].key] })} />
                只同步选中的空间
              </label>
              {!allSpaces && (
                <div className="wiki-space-checks">
                  {spaces.map((s) => (
                    <label key={s.key} className="checkbox small">
                      <input type="checkbox" checked={settings.indexSpaces.includes(s.key)} disabled={busy} onChange={() => toggleSpace(s.key)} />
                      {s.name}
                    </label>
                  ))}
                </div>
              )}
              <p className="muted small">修改范围后会重新同步。首次同步几千个页面需要几分钟，期间可以正常使用。</p>
            </div>
          </div>
        </>
      )}

      <div className="card-section">
        <div className="service-head">
          <span className="service-icon">
            <CheckSquare size={16} />
          </span>
          <div>
            <h3>页面任务</h3>
            <p className="muted small">页面中 @你 的未完成任务自动加入待办；在待办中勾选完成时，同时勾选页面上的任务。需要启用本机 Wiki 库。</p>
          </div>
        </div>
        <label className="checkbox">
          <input type="checkbox" checked={settings.taskTodos} disabled={busy} onChange={(e) => update({ taskTodos: e.target.checked })} />
          把分配给我的页面任务加入待办
        </label>
      </div>

      <div className="card-section">
        <div className="service-head">
          <span className="service-icon">
            <Bell size={16} />
          </span>
          <div>
            <h3>Wiki 动态</h3>
            <p className="muted small">在“动态”中显示 Wiki 上的评论、提到、分享，以及你关注或创建的页面被别人修改。周报页面每天都有人改，不提示。</p>
          </div>
        </div>
        <label className="checkbox">
          <input type="checkbox" checked={settings.activity} disabled={busy} onChange={(e) => update({ activity: e.target.checked })} />
          在动态中显示 Wiki
        </label>
        {settings.activity && (
          <label className="field">
            <span>不提示修改</span>
            <div className="grow">
              <textarea rows={2} value={mutedDraft} placeholder="页面地址或 id，每行一个" onChange={(e) => setMutedDraft(e.target.value)} />
              <div className="row-actions">
                <span className="muted small grow">经常被多人修改的汇总页面可以放在这里。</span>
                <button className="btn" disabled={busy || muted.join(",") === settings.mutedPages.join(",")} onClick={() => update({ mutedPages: muted })}>
                  保存
                </button>
              </div>
            </div>
          </label>
        )}
      </div>
      {error && <p className="notice error">{error}</p>}
    </div>
  );
}
