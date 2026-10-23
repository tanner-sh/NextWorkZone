import { useEffect, useState } from "react";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { FolderSync, RefreshCw } from "lucide-react";
import { api, errorMessage, type WorkspaceSettings } from "../../api";
import { formatTime } from "../../lib/format";
import { workspaceChanged } from "../../lib/workspace";

/** 设置页中的工作空间设置：同步文件夹、Jira 问题自动加入待办。修改后立即生效。 */
export function WorkspaceSettingsCard() {
  const [settings, setSettings] = useState<WorkspaceSettings | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.wsSettings().then(setSettings, (e) => setError(errorMessage(e)));
  }, []);

  const update = async (syncDir: string, jiraTodos: boolean) => {
    setBusy(true);
    setError(null);
    try {
      setSettings(await api.wsSaveSettings(syncDir, jiraTodos));
      workspaceChanged();
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const chooseFolder = async () => {
    const dir = await openDialog({ directory: true, multiple: false, title: "选择同步文件夹" });
    if (typeof dir === "string" && settings) await update(dir, settings.jiraTodos);
  };

  const syncNow = async () => {
    setBusy(true);
    setError(null);
    try {
      await api.wsSync();
      setSettings(await api.wsSettings());
      workspaceChanged();
    } catch (e) {
      setError(errorMessage(e));
      setSettings(await api.wsSettings().catch(() => settings));
    } finally {
      setBusy(false);
    }
  };

  if (!settings) return error ? <p className="notice error">{error}</p> : null;
  const last = settings.lastSync;

  return (
    <div className="card">
      <div className="service-head">
        <span className="service-icon">
          <FolderSync size={16} />
        </span>
        <div>
          <h2>工作空间</h2>
          <p className="muted small">待办、笔记、知识库保存在本机。设置一个同步文件夹（iCloud Drive、坚果云、NAS 等）后，多台电脑会通过它自动同步。</p>
        </div>
      </div>
      <div className="field">
        <span>同步文件夹</span>
        <div className="row-actions grow">
          <input readOnly value={settings.syncDir} placeholder="未设置，仅保存在本机" />
          <button className="btn" disabled={busy} onClick={chooseFolder}>
            选择…
          </button>
          {settings.syncDir && (
            <button className="btn subtle" disabled={busy} onClick={() => update("", settings.jiraTodos)}>
              停止同步
            </button>
          )}
        </div>
      </div>
      {settings.syncDir && (
        <div className="field">
          <span>同步状态</span>
          <div className="row-actions grow">
            <span className={`small grow ${settings.lastError ? "error-text" : "muted"}`}>
              {settings.lastError
                ? `同步失败：${settings.lastError}`
                : last
                  ? `${formatTime(new Date(last.finishedAt).toISOString())} 同步完成 · 其他设备 ${last.devices} 台${last.conflicts ? ` · ${last.conflicts} 个冲突副本` : ""}`
                  : "尚未同步"}
            </span>
            <button className="btn" disabled={busy} onClick={syncNow}>
              <RefreshCw size={14} className={busy ? "spin" : ""} />
              立即同步
            </button>
          </div>
        </div>
      )}
      <label className="checkbox">
        <input type="checkbox" checked={settings.jiraTodos} disabled={busy} onChange={(e) => update(settings.syncDir, e.target.checked)} />
        自动把分配给我的未解决 Jira 问题加入待办（问题解决后自动完成）
      </label>
      {error && <p className="notice error">{error}</p>}
    </div>
  );
}
