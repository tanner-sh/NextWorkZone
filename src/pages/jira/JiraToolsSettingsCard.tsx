import { useEffect, useState } from "react";
import { BellRing, Database, RefreshCw } from "lucide-react";
import { api, errorMessage, type FieldInfo, type JiraToolsSettings } from "../../api";
import { formatTime } from "../../lib/format";
import { checkReminders, useReminders } from "../../lib/reminders";
import { useIndexStatus } from "./IndexStatus";
import { ManageTemplatesDialog } from "./templates";

const DAY_OPTIONS = [
  { days: 180, label: "最近半年" },
  { days: 365, label: "最近一年" },
  { days: 730, label: "最近两年" },
  { days: 1825, label: "最近五年" },
  { days: 0, label: "全部" },
];

/** 设置页中的 Jira 增强功能：本机问题库、到期提醒、模板。修改后立即生效。 */
export function JiraToolsSettingsCard() {
  const [settings, setSettings] = useState<JiraToolsSettings | null>(null);
  const [jqlDraft, setJqlDraft] = useState("");
  const [dateFields, setDateFields] = useState<FieldInfo[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [managing, setManaging] = useState(false);
  const status = useIndexStatus();
  const reminders = useReminders();

  useEffect(() => {
    api.jiraToolsSettings().then((s) => {
      setSettings(s);
      setJqlDraft(s.indexJql);
    }, (e) => setError(errorMessage(e)));
    api.jiraFields().then((list) => setDateFields(list.filter((f) => f.kind === "date" || f.kind === "datetime")), () => {});
  }, []);

  const update = async (patch: Partial<JiraToolsSettings>) => {
    if (!settings) return;
    setBusy(true);
    setError(null);
    try {
      const saved = await api.jiraSaveToolsSettings({ ...settings, ...patch });
      setSettings(saved);
      setJqlDraft(saved.indexJql);
      if ("dueField" in patch || "dueSoonDays" in patch || "staleDays" in patch) void checkReminders(false).catch(() => {});
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setBusy(false);
    }
  };

  const rebuild = async () => {
    setError(null);
    try {
      await api.jiraIndexRebuild();
    } catch (e) {
      setError(errorMessage(e));
    }
  };

  if (!settings) return error ? <p className="notice error">{error}</p> : null;
  const custom = settings.indexJql !== "" || jqlDraft !== "";

  return (
    <div className="card">
      <div className="service-head">
        <span className="service-icon">
          <Database size={16} />
        </span>
        <div>
          <h2>Jira 本机问题库</h2>
          <p className="muted small">把问题的概要、描述和评论同步到本机，搜索即时出结果、可以离线使用，相似问题也会显示别人的处理过程。只读取 Jira，不做任何修改。</p>
        </div>
      </div>
      <label className="checkbox">
        <input type="checkbox" checked={settings.indexEnabled} disabled={busy} onChange={(e) => update({ indexEnabled: e.target.checked })} />
        启用本机问题库（每 10 分钟同步一次有变化的问题）
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
                    ? `正在同步${status.progress ? `：${status.progress.scope} ${status.progress.done}/${status.progress.total}（第 ${status.progress.finished + 1}/${status.progress.scopes} 个范围）` : "…"} · 已有 ${status.count} 个问题`
                    : status.error
                      ? `同步失败：${status.error}`
                      : status.count > 0
                        ? `${status.count} 个问题 · ${status.projects.length} 个项目${status.lastSync ? ` · ${formatTime(status.lastSync)} 同步` : ""}`
                        : "尚未同步"}
              </span>
              <button className="btn" disabled={status?.running} onClick={() => api.jiraIndexSync()}>
                <RefreshCw size={14} className={status?.running ? "spin" : ""} />
                立即同步
              </button>
              <button className="btn subtle" disabled={status?.running} onClick={rebuild} title="清空本机数据后重新同步">
                重建
              </button>
            </div>
          </div>
          {status && status.projects.length > 0 && (
            <div className="field">
              <span>已同步</span>
              <span className="muted small grow">{status.projects.map((p) => `${p.name}（${p.count}）`).join("、")}</span>
            </div>
          )}
          <div className="field">
            <span>范围</span>
            <div className="grow index-scope">
              <label className="checkbox">
                <input type="radio" checked={!custom} disabled={busy} onChange={() => update({ indexJql: "" })} />
                自动：我经办过或报告过问题的项目
              </label>
              <label className="checkbox">
                <input type="radio" checked={custom} disabled={busy} onChange={() => setJqlDraft(jqlDraft || "project in ()")} />
                自定义 JQL
              </label>
              {custom && (
                <div className="row-actions">
                  <input className="grow" value={jqlDraft} placeholder="例如 project in (ABC, DEF)" onChange={(e) => setJqlDraft(e.target.value)} />
                  <button className="btn" disabled={busy || jqlDraft.trim() === settings.indexJql} onClick={() => update({ indexJql: jqlDraft })}>
                    应用
                  </button>
                </div>
              )}
              <select value={settings.indexDays} disabled={busy} onChange={(e) => update({ indexDays: Number(e.target.value) })} title="按创建时间">
                {DAY_OPTIONS.map((o) => (
                  <option key={o.days} value={o.days}>
                    {o.label}创建的问题
                  </option>
                ))}
              </select>
              <p className="muted small">修改范围后会重新同步。首次同步上万个问题需要几分钟，期间可以正常使用。</p>
            </div>
          </div>
        </>
      )}

      <div className="card-section">
        <div className="service-head">
          <span className="service-icon">
            <BellRing size={16} />
          </span>
          <div>
            <h3>到期提醒</h3>
            <p className="muted small">我的未解决问题快到期、已逾期或长时间没有更新时，在列表和首页标出；每天上午第一次检查时发一条系统通知。</p>
          </div>
        </div>
        <label className="field">
          <span>到期字段</span>
          <select value={settings.dueField} disabled={busy} onChange={(e) => update({ dueField: e.target.value })}>
            <option value="">自动识别{!settings.dueField && reminders ? `（当前：${reminders.dueField?.name ?? "未识别到"}）` : ""}</option>
            <option value="duedate">到期日（duedate）</option>
            {dateFields
              .filter((f) => f.id !== "duedate")
              .map((f) => (
                <option key={f.id} value={f.id}>
                  {f.name}
                </option>
              ))}
          </select>
        </label>
        <label className="field">
          <span>提前提醒</span>
          <select value={settings.dueSoonDays} disabled={busy} onChange={(e) => update({ dueSoonDays: Number(e.target.value) })}>
            {[0, 1, 2, 3, 5, 7].map((d) => (
              <option key={d} value={d}>
                {d === 0 ? "只提醒当天和逾期" : `到期前 ${d} 天`}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          <span>停滞提醒</span>
          <select value={settings.staleDays} disabled={busy} onChange={(e) => update({ staleDays: Number(e.target.value) })}>
            {[0, 3, 5, 7, 14, 30].map((d) => (
              <option key={d} value={d}>
                {d === 0 ? "不提醒" : `${d} 天没有更新`}
              </option>
            ))}
          </select>
        </label>
        <label className="checkbox">
          <input type="checkbox" checked={settings.remind} disabled={busy} onChange={(e) => update({ remind: e.target.checked })} />
          发送系统通知（逾期、今天到期的问题，每天一次；当天新出现的再单独通知）
        </label>
      </div>

      <div className="card-section">
        <div className="session-row">
          <div>
            <h3>评论与流转模板</h3>
            <p className="muted small">常用的回复和流转（连同要填的字段）存为模板，一键填好。模板随工作空间同步。</p>
          </div>
          <button className="btn" onClick={() => setManaging(true)}>
            管理模板
          </button>
        </div>
      </div>
      {error && <p className="notice error">{error}</p>}
      {managing && <ManageTemplatesDialog onClose={() => setManaging(false)} />}
    </div>
  );
}
