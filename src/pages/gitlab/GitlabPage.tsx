import { useCallback, useEffect, useMemo, useState } from "react";
import { api, errorMessage, type GlProjectRef, type MrScope, type MrState, type Project } from "../../api";
import { openUrl } from "@tauri-apps/plugin-opener";
import { Copy, ExternalLink, FolderGit2, GitBranch, RefreshCw, Search, Star, StarOff } from "lucide-react";
import { ErrorBox, NotConfigured, Skeleton } from "../../components/common";
import { useContextMenu, type MenuEntry } from "../../components/ContextMenu";
import { toast } from "../../components/Toast";
import { copyText } from "../../lib/clipboard";
import { formatTime } from "../../lib/format";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { MergeRequestView } from "./MergeRequestView";
import { MR_STATES, MrListBody, useMrList } from "./MrList";
import { ProjectView } from "./ProjectView";

const STARRED_KEY = "nextworkzone.gitlab.starred";
const MODE_KEY = "nextworkzone.gitlab.mode";
const SCOPE_KEY = "nextworkzone.gitlab.mrScope";
const LAST_PROJECT_KEY = "nextworkzone.gitlab.lastProject";

type Mode = "mrs" | "projects";

const SCOPES: [MrScope, string][] = [
  ["created_by_me", "我发起的"],
  ["reviewer", "请我审核"],
  ["assigned_to_me", "指派给我"],
];

function readPref<T extends string>(key: string, allowed: readonly T[], fallback: T): T {
  try {
    const v = localStorage.getItem(key) as T | null;
    return v && allowed.includes(v) ? v : fallback;
  } catch {
    return fallback;
  }
}

function writePref(key: string, value: string) {
  try {
    localStorage.setItem(key, value);
  } catch {
    // 忽略
  }
}

function readLastProject(): number | null {
  try {
    return Number(localStorage.getItem(LAST_PROJECT_KEY)) || null;
  } catch {
    return null;
  }
}

function readStarred(): number[] {
  try {
    return JSON.parse(localStorage.getItem(STARRED_KEY) ?? "[]") as number[];
  } catch {
    return [];
  }
}

export function GitlabPage() {
  const { isReady } = useSettings();
  const { current, navigate } = useNav();
  const [projects, setProjects] = useState<Project[] | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState("");
  const [starred, setStarred] = useState<number[]>(readStarred);
  const [selected, setSelected] = useState<number | null>(current.mrIid ? null : current.projectId ?? null);
  const contextMenu = useContextMenu();
  const [mode, setModeState] = useState<Mode>(() => (current.mrIid ? "mrs" : current.projectId || current.projectPath ? "projects" : readPref<Mode>(MODE_KEY, ["mrs", "projects"], "mrs")));
  const [scope, setScopeState] = useState<MrScope>(() => readPref<MrScope>(SCOPE_KEY, ["created_by_me", "reviewer", "assigned_to_me"], "created_by_me"));
  const [mrState, setMrState] = useState<MrState>("opened");
  const [mrInput, setMrInput] = useState("");
  const [mrSearch, setMrSearch] = useState("");
  const [selectedMr, setSelectedMr] = useState<{ project: GlProjectRef; iid: number; id?: number } | null>(() =>
    current.mrIid && (current.projectId || current.projectPath) ? { project: current.projectId ?? current.projectPath!, iid: current.mrIid } : null,
  );
  const mrList = useMrList({ scope }, mrState, mrSearch);
  /** 从链接跳转过来时要打开的分支或提交 */
  const [opening, setOpening] = useState<{ gitRef?: string; commitSha?: string } | null>(() =>
    current.gitRef || current.commitSha ? { gitRef: current.gitRef, commitSha: current.commitSha } : null,
  );

  /** 在列表中手动打开项目：不再带着链接中的分支或提交 */
  const openProject = (id: number) => {
    setOpening(null);
    setSelected(id);
  };

  const setMode = (m: Mode) => {
    setModeState(m);
    writePref(MODE_KEY, m);
  };
  const setScope = (s: MrScope) => {
    setScopeState(s);
    writePref(SCOPE_KEY, s);
  };

  useEffect(() => {
    if (current.page !== "gitlab") return;
    if (current.mrIid && (current.projectId || current.projectPath)) {
      setModeState("mrs");
      setSelectedMr({ project: current.projectId ?? current.projectPath!, iid: current.mrIid });
    } else if (current.projectId || current.projectPath) {
      setModeState("projects");
      setOpening(current.gitRef || current.commitSha ? { gitRef: current.gitRef, commitSha: current.commitSha } : null);
      if (current.projectId) setSelected(current.projectId);
    }
  }, [current]);

  // 从链接跳转过来时只有项目路径：在列表中找，找不到再按名称搜索
  useEffect(() => {
    const path = current.page === "gitlab" && !current.mrIid ? current.projectPath?.toLowerCase() : undefined;
    if (!path || !projects) return;
    const found = projects.find((p) => p.pathWithNamespace.toLowerCase() === path);
    if (found) {
      setSelected(found.id);
      return;
    }
    api.glProjects(path.split("/").pop() ?? path).then(
      (list) => {
        const match = list.find((p) => p.pathWithNamespace.toLowerCase() === path);
        if (match) setSelected(match.id);
        else toast(`没有找到项目 ${current.projectPath}`, true);
      },
      (e) => toast(errorMessage(e), true),
    );
  }, [current, projects]);

  const load = useCallback(async () => {
    setLoading(true);
    setError(null);
    const cached = await api.glCachedProjects().catch(() => null);
    if (cached) setProjects(cached);
    try {
      setProjects(await api.glProjects());
    } catch (e) {
      setError(errorMessage(e));
    } finally {
      setLoading(false);
    }
  }, []);

  const ready = isReady("gitlab");
  useEffect(() => {
    if (ready) void load();
  }, [ready, load]);

  const toggleStar = (id: number) => {
    setStarred((list) => {
      const next = list.includes(id) ? list.filter((x) => x !== id) : [...list, id];
      try {
        localStorage.setItem(STARRED_KEY, JSON.stringify(next));
      } catch {
        // 忽略
      }
      return next;
    });
  };

  const projectMenu = (p: Project): MenuEntry[] => {
    const copy = (text: string) => () =>
      copyText(text).then(
        () => toast("已复制"),
        (e) => toast(`复制失败：${errorMessage(e)}`, true),
      );
    const isStarred = starred.includes(p.id);
    return [
      { label: "打开", icon: <FolderGit2 size={14} />, onSelect: () => openProject(p.id) },
      { label: isStarred ? "取消收藏" : "收藏", icon: isStarred ? <StarOff size={14} /> : <Star size={14} />, onSelect: () => toggleStar(p.id) },
      "separator",
      { label: "复制项目路径", icon: <Copy size={14} />, onSelect: copy(p.pathWithNamespace) },
      { label: "复制克隆地址", icon: <GitBranch size={14} />, onSelect: copy(`${p.webUrl}.git`) },
      { label: "复制网页地址", onSelect: copy(p.webUrl) },
      "separator",
      { label: "在浏览器中打开", icon: <ExternalLink size={14} />, onSelect: () => openUrl(p.webUrl) },
    ];
  };

  const visible = useMemo(() => {
    const q = filter.trim().toLowerCase();
    const list = (projects ?? []).filter((p) => !q || `${p.pathWithNamespace} ${p.description ?? ""}`.toLowerCase().includes(q));
    return [...list.filter((p) => starred.includes(p.id)), ...list.filter((p) => !starred.includes(p.id))];
  }, [projects, filter, starred]);

  // 记住上次打开的项目；没有指定项目时打开它（不在列表里就打开第一个），右侧不留空
  useEffect(() => {
    if (selected !== null) writePref(LAST_PROJECT_KEY, String(selected));
  }, [selected]);
  useEffect(() => {
    if (selected !== null || !projects?.length || (current.page === "gitlab" && current.projectPath)) return;
    const last = readLastProject();
    setSelected(projects.some((p) => p.id === last) ? last : (visible[0]?.id ?? null));
  }, [projects, selected, visible, current]);

  if (!ready) {
    return (
      <section className="page">
        <NotConfigured label="GitLab" onOpenSettings={() => navigate({ page: "settings" })} />
      </section>
    );
  }

  const modeSwitch = (
    <div className="segmented">
      <button className={mode === "mrs" ? "active" : ""} onClick={() => setMode("mrs")}>
        合并请求
      </button>
      <button className={mode === "projects" ? "active" : ""} onClick={() => setMode("projects")}>
        项目
      </button>
    </div>
  );

  if (mode === "mrs") {
    return (
      <div className="split">
        <aside className="list-pane">
          <div className="list-toolbar">
            {modeSwitch}
            <div className="segmented small-seg">
              {SCOPES.map(([id, label]) => (
                <button key={id} className={scope === id ? "active" : ""} onClick={() => setScope(id)}>
                  {label}
                </button>
              ))}
            </div>
            <div className="list-meta">
              <form
                className="input-icon"
                onSubmit={(e) => {
                  e.preventDefault();
                  setMrSearch(mrInput.trim());
                }}
              >
                <Search size={14} />
                <input value={mrInput} placeholder="搜索标题，回车" onChange={(e) => setMrInput(e.target.value)} />
              </form>
              <select className="compact-select" value={mrState} onChange={(e) => setMrState(e.target.value as MrState)} title="状态">
                {MR_STATES.map(([id, label]) => (
                  <option key={id} value={id}>
                    {label}
                  </option>
                ))}
              </select>
              <button className="btn subtle icon" onClick={mrList.reload} disabled={mrList.loading} title="刷新">
                <RefreshCw size={15} className={mrList.loading ? "spin" : ""} />
              </button>
            </div>
            <div className="muted small">{mrList.items ? `${mrList.items.length}${mrList.hasMore ? "+" : ""} 个 · 发起新的合并请求请到「项目」中` : ""}</div>
          </div>
          <MrListBody
            list={mrList}
            selected={selectedMr?.id ?? null}
            showProject
            onOpen={(mr) => setSelectedMr({ project: mr.projectId, iid: mr.iid, id: mr.id })}
            empty={mrSearch ? "没有匹配的合并请求" : "没有合并请求"}
          />
        </aside>
        <section className="detail-pane">
          {selectedMr ? (
            <MergeRequestView key={`${selectedMr.project}!${selectedMr.iid}`} mrRef={selectedMr} onChanged={mrList.replace} />
          ) : (
            <div className="empty-center">选择左侧的合并请求</div>
          )}
        </section>
      </div>
    );
  }

  return (
    <div className="split">
      <aside className="list-pane">
        <div className="list-toolbar">
          {modeSwitch}
          <div className="list-meta">
            <div className="input-icon">
              <Search size={14} />
              <input value={filter} placeholder="筛选项目" onChange={(e) => setFilter(e.target.value)} />
            </div>
            <button className="btn subtle icon" onClick={load} disabled={loading} title="刷新">
              <RefreshCw size={15} className={loading ? "spin" : ""} />
            </button>
          </div>
          <div className="muted small">{projects ? `${projects.length} 个项目 · 收藏的项目置顶` : ""}</div>
        </div>
        {error && <ErrorBox message={error} onRetry={load} />}
        <ul className="issue-list">
          {visible.map((p) => (
            <li key={p.id}>
              <div
                className={`issue-item project-item${selected === p.id ? " selected" : ""}${contextMenu.target === String(p.id) ? " menu-target" : ""}`}
                onClick={() => openProject(p.id)}
                onContextMenu={(e) => contextMenu.open(e, projectMenu(p), String(p.id))}
                role="button"
                tabIndex={0}
              >
                <div className="issue-item-top">
                  <span className="issue-key ellipsis">{p.name}</span>
                  <span className="muted small nowrap project-time">{formatTime(p.lastActivityAt)}</span>
                  <button
                    className={`star${starred.includes(p.id) ? " on" : ""}`}
                    onClick={(e) => {
                      e.stopPropagation();
                      toggleStar(p.id);
                    }}
                    title={starred.includes(p.id) ? "取消收藏" : "收藏"}
                  >
                    <Star size={14} fill={starred.includes(p.id) ? "currentColor" : "none"} />
                  </button>
                </div>
                <div className="muted small ellipsis" title={p.description ? `${p.pathWithNamespace}\n${p.description}` : p.pathWithNamespace}>
                  {p.pathWithNamespace}
                  {p.description && ` · ${p.description}`}
                </div>
              </div>
            </li>
          ))}
          {!projects && !error && (
            <li style={{ padding: "8px 12px" }}>
              <Skeleton lines={8} height={16} />
            </li>
          )}
          {projects && visible.length === 0 && <li className="muted list-empty">没有匹配的项目</li>}
        </ul>
      </aside>
      <section className="detail-pane">
        {selected ? (
          <ProjectView key={`${selected}|${opening?.gitRef ?? ""}|${opening?.commitSha ?? ""}`} projectId={selected} initialRef={opening?.gitRef} initialCommit={opening?.commitSha} />
        ) : (
          <div className="empty-center">选择左侧的项目</div>
        )}
      </section>
      {contextMenu.menu}
    </div>
  );
}
