import { useCallback, useEffect, useState } from "react";
import { listen } from "@tauri-apps/api/event";
import { CheckCircle2, Pause, Play, ShieldAlert, Trash2, X } from "lucide-react";
import { api, CLIP_SETTINGS_EVENT, errorMessage, type ClipboardConfig, type ClipSettings, type IgnoredApp } from "../../../api";
import { formatSize } from "../../../lib/format";
import { useNav } from "../../../state/nav";
import { displayShortcut, ShortcutField } from "../../workspace/WorkspaceSettingsCard";
import { isMac } from "./clip";

const DEFAULT_SHORTCUT = "CommandOrControl+Alt+V";
const KEEP_DAYS = [
  { value: 1, label: "1 天" },
  { value: 7, label: "1 周" },
  { value: 30, label: "1 个月" },
  { value: 90, label: "3 个月" },
  { value: 365, label: "1 年" },
  { value: 0, label: "永久" },
];
const MAX_ITEMS = [500, 1000, 5000, 10000, 0];
const MAX_IMAGE_MB = [10, 50, 200, 0];

/** 剪贴板设置，修改后立即生效。 */
export function useClipSettings() {
  const [settings, setSettings] = useState<ClipSettings | null>(null);
  const [error, setError] = useState<string | null>(null);
  const refresh = useCallback(() => void api.clipSettings().then(setSettings, (e) => setError(errorMessage(e))), []);
  useEffect(() => {
    refresh();
    // 回到应用时（可能刚在系统设置中授了权）刷新权限状态
    window.addEventListener("focus", refresh);
    const unlisten = listen(CLIP_SETTINGS_EVENT, refresh);
    return () => {
      window.removeEventListener("focus", refresh);
      void unlisten.then((fn) => fn());
    };
  }, [refresh]);
  const save = async (patch: Partial<ClipboardConfig>) => {
    if (!settings) return;
    setError(null);
    try {
      setSettings(await api.clipSaveSettings({ ...settings.config, ...patch }));
    } catch (e) {
      setError(errorMessage(e));
    }
  };
  return { settings, setSettings, error, save };
}

function pausedText(until: number): string {
  if (until > Date.now() + 365 * 86_400_000) return "已暂停记录，直到手动恢复";
  const d = new Date(until);
  return `已暂停记录，${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")} 自动恢复`;
}

/** 设置页“工具”卡片中的简要设置。 */
export function ClipboardSummary() {
  const { settings, error, save } = useClipSettings();
  if (!settings) return error ? <p className="notice error small">{error}</p> : null;
  return (
    <div className="tool-summary">
      <label className="checkbox">
        <input type="checkbox" checked={settings.config.enabled} onChange={(e) => void save({ enabled: e.target.checked })} />
        记录剪贴板历史
      </label>
      {settings.config.enabled && <span className="muted small">快捷键 {displayShortcut(settings.config.shortcut)} · 已保存 {settings.stats.items.toLocaleString()} 条</span>}
      {error && <p className="notice error small">{error}</p>}
    </div>
  );
}

export function ClipboardSettings() {
  const { settings, setSettings, error, save } = useClipSettings();
  const { navigate } = useNav();
  const [candidates, setCandidates] = useState<IgnoredApp[]>([]);
  const [confirmClear, setConfirmClear] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  useEffect(() => {
    api.clipIgnoreCandidates().then(setCandidates, () => {});
  }, [settings?.config.ignoredApps.length]);

  if (!settings) return error ? <p className="notice error">{error}</p> : null;
  const { config } = settings;

  const pause = async (minutes: number) => setSettings(await api.clipPause(minutes));

  return (
    <div className="clip-settings">
      <div className="card">
        <h2>基本</h2>
        <label className="checkbox">
          <input type="checkbox" checked={config.enabled} onChange={(e) => void save({ enabled: e.target.checked })} />
          记录剪贴板历史
        </label>
        <p className="muted small indent">关闭后不再记录新的内容，快捷键也不再生效；已有的历史和置顶板保留。</p>
        <div className="field">
          <span>打开面板</span>
          <div className="grow">
            <ShortcutField value={config.shortcut} disabled={!config.enabled} defaultValue={DEFAULT_SHORTCUT} onChange={(shortcut) => void save({ shortcut })} />
            <p className="muted small">在任何应用中按下快捷键，从屏幕底部弹出剪贴板面板。</p>
            {settings.shortcutError && <p className="notice error small">{settings.shortcutError}</p>}
          </div>
        </div>
        <div className="field">
          <span>暂停记录</span>
          <div className="row-actions grow">
            {settings.pausedUntil ? (
              <>
                <span className="small warn-text">
                  <Pause size={13} /> {pausedText(settings.pausedUntil)}
                </span>
                <button className="btn" onClick={() => void pause(0)}>
                  <Play size={14} />
                  恢复
                </button>
              </>
            ) : (
              <>
                <button className="btn" onClick={() => void pause(15)}>
                  15 分钟
                </button>
                <button className="btn" onClick={() => void pause(60)}>
                  1 小时
                </button>
                <button className="btn" onClick={() => void pause(-1)}>
                  直到手动恢复
                </button>
                <span className="muted small">例如要复制敏感内容时；托盘菜单中也可以暂停。</span>
              </>
            )}
          </div>
        </div>
      </div>

      <div className="card">
        <h2>粘贴</h2>
        <label className="checkbox">
          <input type="checkbox" checked={config.autoPaste} onChange={(e) => void save({ autoPaste: e.target.checked })} />
          选中后直接粘贴到之前使用的应用
        </label>
        {config.autoPaste && (
          <div className="indent">
            {settings.pasteSupport === "ready" ? (
              <p className="small ok-text">
                <CheckCircle2 size={13} /> 可以直接粘贴
              </p>
            ) : settings.pasteSupport === "needsPermission" ? (
              <div className="notice warn small">
                <ShieldAlert size={14} />
                <span className="grow">
                  需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许 NextWorkZone，才能替你按下 ⌘V。授权前选中条目只会复制到剪贴板。
                </span>
                <button className="btn small-btn" onClick={() => void api.clipRequestPermission()}>
                  去授权
                </button>
              </div>
            ) : (
              <p className="notice warn small">{settings.pasteNote ?? "当前系统不支持自动粘贴"}，选中条目只会复制到剪贴板。</p>
            )}
          </div>
        )}
        <label className="checkbox">
          <input type="checkbox" checked={config.plainText} onChange={(e) => void save({ plainText: e.target.checked })} />
          默认粘贴为纯文本（去掉网页、文档中的格式）
        </label>
        <p className="muted small indent">{config.plainText ? "需要保留格式时，在面板中按" : "需要去掉格式时，在面板中按"} ⇧↩。</p>
      </div>

      <div className="card">
        <h2>保留</h2>
        <div className="field">
          <span>保留时长</span>
          <div className="segmented">
            {KEEP_DAYS.map((d) => (
              <button key={d.value} className={config.keepDays === d.value ? "active" : ""} onClick={() => void save({ keepDays: d.value })}>
                {d.label}
              </button>
            ))}
          </div>
        </div>
        <div className="field">
          <span>最多保留</span>
          <div className="segmented">
            {MAX_ITEMS.map((n) => (
              <button key={n} className={config.maxItems === n ? "active" : ""} onClick={() => void save({ maxItems: n })}>
                {n ? `${n.toLocaleString()} 条` : "不限"}
              </button>
            ))}
          </div>
        </div>
        <p className="muted small">置顶的条目不受影响，始终保留。</p>
        <label className="checkbox">
          <input type="checkbox" checked={config.saveImages} onChange={(e) => void save({ saveImages: e.target.checked })} />
          记录复制的图片（截图等）
        </label>
        {config.saveImages && (
          <div className="field indent">
            <span>图片上限</span>
            <div className="segmented">
              {MAX_IMAGE_MB.map((n) => (
                <button key={n} className={config.maxImageMb === n ? "active" : ""} onClick={() => void save({ maxImageMb: n })}>
                  {n ? `${n} MB` : "不限"}
                </button>
              ))}
            </div>
          </div>
        )}
        <div className="field">
          <span>已保存</span>
          <div className="row-actions grow">
            <span className="small muted grow">
              {settings.stats.items.toLocaleString()} 条，其中置顶 {settings.stats.pinned} 条；图片占用 {formatSize(settings.stats.imageBytes)}
            </span>
            <button
              className={`btn ${confirmClear ? "danger" : "subtle"}`}
              onClick={async () => {
                if (!confirmClear) return setConfirmClear(true);
                setConfirmClear(false);
                const removed = await api.clipClear();
                setMessage(`已清除 ${removed} 条历史`);
              }}
              onBlur={() => setConfirmClear(false)}
            >
              <Trash2 size={14} />
              {confirmClear ? "确认清除（置顶的保留）" : "清除历史"}
            </button>
          </div>
        </div>
        {message && <p className="muted small">{message}</p>}
      </div>

      <div className="card">
        <h2>隐私</h2>
        <p className="muted small">所有内容只保存在本机（{settings.dataDir}），不会同步或上传。</p>
        <label className="checkbox">
          <input type="checkbox" checked={config.skipSecrets} onChange={(e) => void save({ skipSecrets: e.target.checked })} />
          不记录疑似密码、密钥的内容（私钥、常见服务的访问令牌、像随机密码的短文字）
        </label>
        <p className="muted small indent">密码管理器复制的密码带有“不要记录”的标记，始终不会记录。</p>
        <div className="field">
          <span>忽略的应用</span>
          <div className="grow">
            <div className="clip-ignored">
              {settings.builtinIgnored.map((a) => (
                <span key={a.id} className="chip muted" title={`${a.id}（内置，始终忽略）`}>
                  {a.name}
                </span>
              ))}
              {config.ignoredApps.map((a) => (
                <span key={a.id} className="chip" title={a.id}>
                  {a.name}
                  <button className="chip-x" title="不再忽略" onClick={() => void save({ ignoredApps: config.ignoredApps.filter((x) => x.id !== a.id) })}>
                    <X size={11} />
                  </button>
                </span>
              ))}
            </div>
            {candidates.length > 0 && (
              <select
                className="clip-ignore-add"
                value=""
                onChange={(e) => {
                  const app = candidates.find((c) => c.id === e.target.value);
                  if (app) void save({ ignoredApps: [...config.ignoredApps, app] });
                }}
              >
                <option value="">添加要忽略的应用…</option>
                {candidates.map((c) => (
                  <option key={c.id} value={c.id}>
                    {c.name}
                  </option>
                ))}
              </select>
            )}
            <p className="muted small">在这些应用中复制的内容不会被记录。列表中是曾经复制过内容的应用{isMac ? "" : "（按可执行文件识别）"}。</p>
          </div>
        </div>
      </div>
      {error && <p className="notice error">{error}</p>}
      <p className="muted small">
        面板中的操作：↩ 粘贴 · ⇧↩ 粘贴为纯文本 · 空格 预览 · {isMac ? "⌘" : "Ctrl+"}E 编辑后粘贴 · {isMac ? "⌘" : "Ctrl+"}1–9 快速粘贴 · Tab 切换置顶板 · ⇧←/→ 或{" "}
        {isMac ? "⌘" : "Ctrl+"}点击 多选。{" "}
        <button className="link-btn" onClick={() => navigate({ page: "tools", tool: "clipboard" })}>
          查看历史
        </button>
      </p>
    </div>
  );
}
