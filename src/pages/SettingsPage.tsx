import { useEffect, useState, type ComponentType } from "react";
import { BookOpen, CircleDot, FileDown, FolderGit2, Globe, NotebookPen, type LucideProps } from "lucide-react";
import { api, errorMessage, type ConnectionInfo, type Service, type Settings } from "../api";
import { useSettings } from "../state/settings";
import { WorkspaceSettingsCard } from "./workspace/WorkspaceSettingsCard";
import { JiraToolsSettingsCard } from "./jira/JiraToolsSettingsCard";
import { WikiToolsSettingsCard } from "./wiki/WikiToolsSettingsCard";
import { ToolsSettingsCard } from "../tools/ToolsSettingsCard";

type TestState =
  | { status: "idle" }
  | { status: "testing" }
  | { status: "ok"; info: ConnectionInfo }
  | { status: "error"; message: string };

type WebAccounts = Partial<Record<Service, { username: string; password: string }>>;

const SERVICE_META: Record<Service, { kind: string; placeholder: string; icon: ComponentType<LucideProps> }> = {
  jira: { kind: "Jira Server / Data Center", placeholder: "https://jira.example.com", icon: CircleDot },
  confluence: { kind: "Confluence Server / Data Center", placeholder: "https://wiki.example.com", icon: BookOpen },
  gitlab: { kind: "GitLab", placeholder: "https://gitlab.example.com", icon: FolderGit2 },
};

export function SettingsPage() {
  const { settings, setSettings, webAccess, refreshSessions } = useSettings();
  const [proxy, setProxy] = useState("");
  const [baseUrls, setBaseUrls] = useState<Partial<Record<Service, string>>>({});
  const [tokens, setTokens] = useState<Partial<Record<Service, string>>>({});
  const [webAccounts, setWebAccounts] = useState<WebAccounts>({});
  const [weeklyPage, setWeeklyPage] = useState("");
  const [weeklyName, setWeeklyName] = useState("");
  const [tests, setTests] = useState<Partial<Record<Service, TestState>>>({});
  const [notice, setNotice] = useState<{ kind: "ok" | "error"; text: string } | null>(null);
  const [saving, setSaving] = useState(false);

  const fill = (next: Settings) => {
    setProxy(next.proxy);
    setBaseUrls(Object.fromEntries(next.services.map((s) => [s.service, s.baseUrl])));
    setTokens({});
    setWebAccounts(Object.fromEntries(next.services.filter((s) => s.supportsWebLogin).map((s) => [s.service, { username: s.webUsername, password: "" }])));
    setWeeklyPage(next.weeklyPageId);
    setWeeklyName(next.weeklyPersonName);
  };

  const apply = (next: Settings) => {
    setSettings(next);
    fill(next);
  };

  useEffect(() => {
    if (settings) fill(settings);
    // 只在首次拿到设置时填充表单，避免覆盖正在编辑的内容
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [settings === null]);

  const dirty =
    settings !== null &&
    (proxy !== settings.proxy ||
      settings.services.some((s) => {
        const account = webAccounts[s.service];
        return (
          (baseUrls[s.service] ?? "") !== s.baseUrl ||
          Boolean(tokens[s.service]?.trim()) ||
          (s.supportsWebLogin && account !== undefined && (account.username !== s.webUsername || account.password !== ""))
        );
      }) ||
      weeklyPage !== settings.weeklyPageId ||
      weeklyName !== settings.weeklyPersonName);

  const save = async () => {
    setSaving(true);
    try {
      apply(await api.saveSettings({ proxy, baseUrls, tokens, weeklyPage, weeklyPersonName: weeklyName, webAccounts }));
      setTests({});
      setNotice({ kind: "ok", text: "设置已保存" });
    } catch (e) {
      setNotice({ kind: "error", text: errorMessage(e) });
    } finally {
      setSaving(false);
    }
  };

  const importEnv = async () => {
    try {
      const imported = await api.importTokensEnv();
      apply(await api.getSettings());
      setTests({});
      setNotice({ kind: "ok", text: imported.length ? `已从 ~/.nextworkzone/tokens.env 导入 ${imported.length} 个令牌` : "tokens.env 中没有可导入的令牌" });
    } catch (e) {
      setNotice({ kind: "error", text: errorMessage(e) });
    }
  };

  const clearToken = async (service: Service) => {
    try {
      apply(await api.clearToken(service));
      setTests((t) => ({ ...t, [service]: { status: "idle" } }));
    } catch (e) {
      setNotice({ kind: "error", text: errorMessage(e) });
    }
  };

  const test = async (service: Service) => {
    setTests((t) => ({ ...t, [service]: { status: "testing" } }));
    try {
      const info = await api.testConnection(service);
      setTests((t) => ({ ...t, [service]: { status: "ok", info } }));
    } catch (e) {
      setTests((t) => ({ ...t, [service]: { status: "error", message: errorMessage(e) } }));
    }
  };

  const setAccount = (service: Service, patch: Partial<{ username: string; password: string }>) =>
    setWebAccounts((all) => ({ ...all, [service]: { username: "", password: "", ...all[service], ...patch } }));

  const jiraConnected = Boolean(settings?.services.some((s) => s.service === "jira" && s.baseUrl && s.hasToken));
  const wikiConnected = Boolean(settings?.services.some((s) => s.service === "confluence" && s.baseUrl && s.hasToken));
  const sections = [
    { id: "settings-workspace", group: "常规", label: "工作空间" },
    { id: "settings-tools", group: "常规", label: "工具" },
    ...(jiraConnected ? [{ id: "settings-jira-tools", group: "常规", label: "Jira 本机问题库" }] : []),
    ...(wikiConnected ? [{ id: "settings-wiki-tools", group: "常规", label: "Wiki 本机库" }] : []),
    { id: "settings-network", group: "连接", label: "网络" },
    ...(settings?.services ?? []).map((s) => ({ id: `settings-${s.service}`, group: "连接", label: s.label })),
    { id: "settings-weekly", group: "连接", label: "周报" },
  ];

  if (!settings) {
    return <section className="page">{notice ? <p className="notice error">{notice.text}</p> : <p className="muted">加载中…</p>}</section>;
  }

  return (
    <section className="page">
      <header className="page-header">
        <div>
          <h1>设置</h1>
          <p className="muted">工作空间、工具，以及连接的系统地址与凭据。凭据只保存在本机。</p>
        </div>
        {import.meta.env.DEV && (
          <button className="btn" onClick={importEnv} title="开发用：从 ~/.nextworkzone/tokens.env 导入">
            <FileDown size={14} />
            导入 tokens.env
          </button>
        )}
      </header>

      {notice && <p className={`notice ${notice.kind}`}>{notice.text}</p>}

      <div className="settings-layout">
        <nav className="settings-nav">
          {sections.map((sec, i) => (
            <div key={sec.id}>
              {(i === 0 || sec.group !== sections[i - 1].group) && <div className="settings-nav-group">{sec.group}</div>}
              <button className="settings-nav-item" onClick={() => document.getElementById(sec.id)?.scrollIntoView({ behavior: "smooth", block: "start" })}>
                {sec.label}
              </button>
            </div>
          ))}
        </nav>
        <div className="settings-body">
          <h2 className="settings-group">
            常规<span className="muted small">修改后立即生效</span>
          </h2>
          <div id="settings-workspace">
            <WorkspaceSettingsCard />
          </div>
          <div id="settings-tools">
            <ToolsSettingsCard />
          </div>
          {jiraConnected && (
            <div id="settings-jira-tools">
              <JiraToolsSettingsCard />
            </div>
          )}
          {wikiConnected && (
            <div id="settings-wiki-tools">
              <WikiToolsSettingsCard />
            </div>
          )}

          <h2 className="settings-group">
            连接<span className="muted small">修改后需要保存</span>
          </h2>
          <div className="card" id="settings-network">
            <div className="service-head">
              <span className="service-icon">
                <Globe size={16} />
              </span>
              <h2>网络</h2>
            </div>
            <label className="field">
              <span>代理</span>
              <input value={proxy} placeholder="留空则使用系统代理，例如 http://127.0.0.1:7890" onChange={(e) => setProxy(e.target.value)} />
            </label>
          </div>

          {settings.services.map((s) => {
            const state = tests[s.service] ?? { status: "idle" };
            const meta = SERVICE_META[s.service];
            const Icon = meta.icon;
            const account = webAccounts[s.service] ?? { username: "", password: "" };
            const access = webAccess(s.service);
            return (
              <div className="card" key={s.service} id={`settings-${s.service}`}>
                <div className="card-title">
                  <div className="service-head">
                    <span className="service-icon">
                      <Icon size={16} />
                    </span>
                    <div>
                      <h2>{s.label}</h2>
                      <p className="muted small">{meta.kind}</p>
                    </div>
                  </div>
                  <TestResult state={state} />
                </div>
                <label className="field">
                  <span>地址</span>
                  <input value={baseUrls[s.service] ?? ""} placeholder={meta.placeholder} onChange={(e) => setBaseUrls((u) => ({ ...u, [s.service]: e.target.value }))} />
                </label>
                <label className="field">
                  <span>访问令牌</span>
                  <input
                    type="password"
                    value={tokens[s.service] ?? ""}
                    placeholder={s.hasToken ? "已保存（留空则不修改）" : "个人访问令牌（Personal Access Token）"}
                    onChange={(e) => setTokens((t) => ({ ...t, [s.service]: e.target.value }))}
                  />
                </label>
                <div className="card-actions">
                  <button className="btn" disabled={dirty || !s.baseUrl || !s.hasToken || state.status === "testing"} onClick={() => test(s.service)}>
                    测试连接
                  </button>
                  {s.hasToken && (
                    <button className="btn subtle" onClick={() => clearToken(s.service)}>
                      删除令牌
                    </button>
                  )}
                  {dirty && <span className="muted small">保存后可测试</span>}
                </div>

                {s.supportsWebLogin && (
                  <div className="card-section">
                    <div className="session-row">
                      <div>
                        <h3>网页登录</h3>
                        <p className="muted small">附件、图片等网页内容不走 API。若服务器要求单独的网页登录（例如启用了 2FA 或 SSO），在这里登录一次即可。</p>
                      </div>
                      <WebAccessState access={access} />
                    </div>
                    <label className="field">
                      <span>账号</span>
                      <input value={account.username} autoComplete="off" placeholder="可选，用于登录窗口自动填写" onChange={(e) => setAccount(s.service, { username: e.target.value })} />
                    </label>
                    <label className="field">
                      <span>密码</span>
                      <input
                        type="password"
                        autoComplete="new-password"
                        value={account.password}
                        placeholder={s.hasWebPassword ? "已保存（留空则不修改）" : "可选"}
                        onChange={(e) => setAccount(s.service, { password: e.target.value })}
                      />
                    </label>
                    <div className="card-actions">
                      {access === "session" ? (
                        <button className="btn" onClick={() => api.webLogout(s.service).then(refreshSessions)}>
                          退出网页登录
                        </button>
                      ) : (
                        <button className="btn" disabled={!s.baseUrl || access === "token"} onClick={() => api.webLogin(s.service).catch((e) => setNotice({ kind: "error", text: errorMessage(e) }))}>
                          网页登录
                        </button>
                      )}
                      <span className="muted small">填写账号密码后，登录窗口会自动填写并提交，你只需完成额外的验证步骤。</span>
                    </div>
                  </div>
                )}
              </div>
            );
          })}

          <div className="card" id="settings-weekly">
            <div className="service-head">
              <span className="service-icon">
                <NotebookPen size={16} />
              </span>
              <div>
                <h2>周报</h2>
                <p className="muted small">每周一个以日期范围开头的一级标题，表格中第一列是人名的那一行即为你的周报。</p>
              </div>
            </div>
            <label className="field">
              <span>周报页面</span>
              <input value={weeklyPage} placeholder="Wiki 页面地址或页面 ID" onChange={(e) => setWeeklyPage(e.target.value)} />
            </label>
            <label className="field">
              <span>我的名字</span>
              <input value={weeklyName} placeholder="表格第一列中你的名字，留空则使用 Wiki 显示名" onChange={(e) => setWeeklyName(e.target.value)} />
            </label>
          </div>

          {/* 有未保存的修改时固定在底部，滚到哪里都能保存 */}
          {dirty && (
            <div className="save-bar">
              <span className="grow">连接设置有未保存的修改</span>
              <button className="btn subtle" disabled={saving} onClick={() => fill(settings)}>
                放弃修改
              </button>
              <button className="btn primary" disabled={saving} onClick={save}>
                {saving ? "保存中…" : "保存"}
              </button>
            </div>
          )}
        </div>
      </div>
    </section>
  );
}

function WebAccessState({ access }: { access: string | undefined }) {
  const [dot, text] =
    access === "token" ? ["ok", "令牌即可访问，无需登录"] : access === "session" ? ["ok", "已登录"] : access === "loginRequired" ? ["warn", "需要登录"] : ["", "检测中"];
  return (
    <span className="session-state nowrap">
      <span className={`dot ${dot}`} />
      {text}
    </span>
  );
}

function TestResult({ state }: { state: TestState }) {
  switch (state.status) {
    case "idle":
      return null;
    case "testing":
      return <span className="pill">测试中…</span>;
    case "ok":
      return (
        <span className="pill ok">
          ✓ {state.info.displayName}（{state.info.username}）{state.info.serverVersion && ` · v${state.info.serverVersion}`}
        </span>
      );
    case "error":
      return (
        <span className="pill error" title={state.message}>
          ✗ {state.message}
        </span>
      );
  }
}
