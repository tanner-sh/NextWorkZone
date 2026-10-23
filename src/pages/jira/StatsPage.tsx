import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { ExternalLink } from "lucide-react";
import { api, errorMessage, type IssueSummary } from "../../api";
import { ErrorBox, NotConfigured, Skeleton, SysImg } from "../../components/common";
import { useMenus } from "../../components/MenuHost";
import { parseTime } from "../../lib/format";
import { addDays, dayString, today } from "../../lib/workspace";
import { useNav } from "../../state/nav";
import { useSettings } from "../../state/settings";
import { MY_UNRESOLVED_JQL } from "./jql";

type PeriodId = "thisWeek" | "lastWeek" | "thisMonth" | "lastMonth" | "last90" | "thisYear";

const PERIODS: { id: PeriodId; label: string }[] = [
  { id: "thisWeek", label: "本周" },
  { id: "lastWeek", label: "上周" },
  { id: "thisMonth", label: "本月" },
  { id: "lastMonth", label: "上月" },
  { id: "last90", label: "近 90 天" },
  { id: "thisYear", label: "今年" },
];

/** 时间段的起止日期（含两端）。 */
function rangeOf(id: PeriodId): { from: string; to: string } {
  const t = today();
  const now = new Date();
  const monday = addDays(t, -((now.getDay() + 6) % 7));
  const firstOfMonth = dayString(new Date(now.getFullYear(), now.getMonth(), 1));
  switch (id) {
    case "thisWeek":
      return { from: monday, to: t };
    case "lastWeek":
      return { from: addDays(monday, -7), to: addDays(monday, -1) };
    case "thisMonth":
      return { from: firstOfMonth, to: t };
    case "lastMonth":
      return { from: dayString(new Date(now.getFullYear(), now.getMonth() - 1, 1)), to: addDays(firstOfMonth, -1) };
    case "last90":
      return { from: addDays(t, -89), to: t };
    case "thisYear":
      return { from: `${now.getFullYear()}-01-01`, to: t };
  }
}

/** 统计中最多取的问题数。 */
const MAX_ISSUES = 1000;
const EXTRA = ["components", "resolutiondate"];

async function searchAll(jql: string): Promise<{ issues: IssueSummary[]; total: number }> {
  const issues: IssueSummary[] = [];
  let total = 0;
  do {
    const page = await api.jiraSearch(jql, issues.length, 100, EXTRA);
    total = page.total;
    issues.push(...page.issues);
    if (page.issues.length === 0) break;
  } while (issues.length < Math.min(total, MAX_ISSUES));
  return { issues, total };
}

interface Stats {
  handled: { issues: IssueSummary[]; total: number };
  resolved: { issues: IssueSummary[]; total: number };
  assigned: number;
  unresolved: number;
  worklogSeconds: number | null;
}

function queries(from: string, to: string) {
  const end = addDays(to, 1);
  const during = `DURING ("${from}", "${end}")`;
  return {
    handled: `status changed by currentUser() ${during} ORDER BY updated DESC`,
    resolved: `resolved >= "${from}" AND resolved < "${end}" AND (assignee = currentUser() OR status changed by currentUser() ${during}) ORDER BY resolved DESC`,
    assigned: `assignee changed to currentUser() ${during}`,
  };
}

/** 个人统计：一段时间内处理、解决的问题，处理时长，按项目、模块、类型的分布。 */
export function StatsPage() {
  const { isReady } = useSettings();
  const { navigate } = useNav();
  const [period, setPeriod] = useState<PeriodId>("thisMonth");
  const [stats, setStats] = useState<Stats | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const range = useMemo(() => rangeOf(period), [period]);
  const q = useMemo(() => queries(range.from, range.to), [range]);

  useEffect(() => {
    if (!isReady("jira")) return;
    let alive = true;
    setLoading(true);
    setError(null);
    Promise.all([
      searchAll(q.handled),
      searchAll(q.resolved),
      api.jiraSearch(q.assigned, 0, 1),
      api.jiraSearch(MY_UNRESOLVED_JQL, 0, 1),
      api.jiraMyWorklogs(range.from, range.to).then((list) => list.reduce((n, w) => n + w.seconds, 0), () => null),
    ]).then(
      ([handled, resolved, assigned, unresolved, worklogSeconds]) => {
        if (!alive) return;
        setStats({ handled, resolved, assigned: assigned.total, unresolved: unresolved.total, worklogSeconds });
        setLoading(false);
      },
      (e) => {
        if (!alive) return;
        setError(errorMessage(e));
        setLoading(false);
      },
    );
    return () => {
      alive = false;
    };
  }, [q, range, isReady]);

  if (!isReady("jira")) {
    return (
      <section className="page">
        <NotConfigured label="Jira" onOpenSettings={() => navigate({ page: "settings" })} />
      </section>
    );
  }

  return (
    <section className="page stats-page">
      <header className="page-header">
        <div>
          <h1>统计</h1>
          <p className="muted small">
            {range.from} 至 {range.to} · 处理过：你修改过状态的问题；解决：这段时间内解决、经办人是你或由你流转的问题；解决用时：从创建到解决
          </p>
        </div>
      </header>
      <div className="segmented">
        {PERIODS.map((p) => (
          <button key={p.id} className={period === p.id ? "active" : ""} onClick={() => setPeriod(p.id)}>
            {p.label}
          </button>
        ))}
      </div>
      {error && <ErrorBox message={error} />}
      {!stats && !error && <Skeleton lines={8} height={18} />}
      {stats && <StatsBody stats={stats} range={range} queries={q} loading={loading} />}
    </section>
  );
}

function median(values: number[]): number | null {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  const mid = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
}

const DAY_MS = 86400000;

function formatDays(days: number): string {
  if (days < 1) return `${Math.max(1, Math.round(days * 24))} 小时`;
  return `${days < 10 ? days.toFixed(1) : Math.round(days)} 天`;
}

function formatHours(seconds: number): string {
  const hours = seconds / 3600;
  return hours < 10 ? `${Number(hours.toFixed(1))}h` : `${Math.round(hours)}h`;
}

function StatsBody({ stats, range, queries: q, loading }: { stats: Stats; range: { from: string; to: string }; queries: ReturnType<typeof queries>; loading: boolean }) {
  const { navigate } = useNav();
  const menus = useMenus();
  const resolved = stats.resolved.issues;
  const durations = resolved.map((i) => i.extra?.resolutiondate && (parseTime(i.extra.resolutiondate).getTime() - parseTime(i.created).getTime()) / DAY_MS).filter((d): d is number => typeof d === "number" && d >= 0);
  const medianDays = median(durations);
  const buckets = useMemo(() => bucketize(resolved, range.from, range.to), [resolved, range]);
  const handled = stats.handled.issues;
  const open = (jql: string) => navigate({ page: "jira", jql });

  return (
    <div className={`stats-body${loading ? " refreshing" : ""}`}>
      <div className="kpi-row">
        <Kpi label="处理过的问题" value={stats.handled.total} onClick={() => open(q.handled)} />
        <Kpi label="解决的问题" value={stats.resolved.total} onClick={() => open(q.resolved)} />
        <Kpi label="新分配给我" value={stats.assigned} onClick={() => open(q.assigned)} />
        <Kpi label="当前未解决" value={stats.unresolved} onClick={() => open(MY_UNRESOLVED_JQL)} />
        <Kpi label="解决用时（中位数）" value={medianDays === null ? "—" : formatDays(medianDays)} hint={durations.length > 0 ? `共 ${durations.length} 个问题` : undefined} />
        <Kpi label="登记工时" value={stats.worklogSeconds === null ? "—" : formatHours(stats.worklogSeconds)} hint={stats.worklogSeconds === 0 ? "这段时间没有登记" : undefined} />
      </div>

      <div className="card">
        <div className="card-title">
          <h2>解决的问题 · 按{buckets.unit}</h2>
        </div>
        {resolved.length === 0 ? <p className="muted">这段时间没有解决的问题</p> : <ColumnChart buckets={buckets.items} />}
      </div>

      <div className="stats-grid">
        <Breakdown title="按项目" issues={handled} keyOf={(i) => [i.project.name]} />
        <Breakdown title="按模块" issues={handled} keyOf={(i) => (i.extra?.components ? i.extra.components.split("、") : ["未设置模块"])} />
        <Breakdown title="按问题类型" issues={handled} keyOf={(i) => [i.issueType.name]} />
      </div>

      <div className="card">
        <div className="card-title">
          <h2>解决的问题 {stats.resolved.total > resolved.length && <span className="muted small">（显示前 {resolved.length} 个）</span>}</h2>
          <button className="btn subtle" onClick={() => open(q.resolved)}>
            在列表中查看 <ExternalLink size={13} />
          </button>
        </div>
        <table className="stats-table">
          <thead>
            <tr>
              <th>问题</th>
              <th>项目</th>
              <th className="num">解决时间</th>
              <th className="num">解决用时</th>
            </tr>
          </thead>
          <tbody>
            {resolved.slice(0, 200).map((i) => {
              const at = i.extra?.resolutiondate;
              const days = at ? (parseTime(at).getTime() - parseTime(i.created).getTime()) / DAY_MS : null;
              return (
                <tr key={i.key} className={menus.target === i.key ? "menu-target" : undefined} onClick={() => navigate({ page: "jira", issueKey: i.key })} onContextMenu={(e) => menus.open(e, menus.issue(i), i.key)}>
                  <td>
                    <span className="stats-issue">
                      <SysImg service="jira" src={i.issueType.iconUrl} className="icon16" />
                      <span className="issue-key nowrap">{i.key}</span>
                      <span className="ellipsis">{i.summary}</span>
                    </span>
                  </td>
                  <td className="muted ellipsis">{i.project.name}</td>
                  <td className="num muted">{at ? at.slice(0, 10) : "—"}</td>
                  <td className="num">{days === null ? "—" : formatDays(days)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function Kpi({ label, value, hint, onClick }: { label: string; value: number | string; hint?: string; onClick?: () => void }) {
  const body = (
    <>
      <span className="kpi-label">{label}</span>
      <span className="kpi-value">{value}</span>
      {hint && <span className="muted small">{hint}</span>}
    </>
  );
  return onClick ? (
    <button className="kpi" onClick={onClick} title="在问题列表中查看">
      {body}
    </button>
  ) : (
    <div className="kpi">{body}</div>
  );
}

// ---------- 按时间分桶 ----------

interface Bucket {
  label: string;
  /** 悬停时显示的完整范围 */
  title: string;
  count: number;
}

/** 按本地时区解析 YYYY-MM-DD（new Date("YYYY-MM-DD") 会按 UTC 解析）。 */
function localDate(day: string): Date {
  const [y, m, d] = day.split("-").map(Number);
  return new Date(y, m - 1, d);
}

/** 31 天以内按天，半年以内按周，更长按月。 */
function bucketize(issues: IssueSummary[], from: string, to: string): { unit: string; items: Bucket[] } {
  const span = Math.round((localDate(to).getTime() - localDate(from).getTime()) / DAY_MS) + 1;
  const unit = span <= 31 ? "天" : span <= 190 ? "周" : "月";
  const keyOf = (day: string): string => {
    if (unit === "天") return day;
    if (unit === "月") return day.slice(0, 7);
    return addDays(day, -((localDate(day).getDay() + 6) % 7));
  };
  const items: Bucket[] = [];
  const index = new Map<string, Bucket>();
  for (let day = from; day <= to; day = addDays(day, 1)) {
    const key = keyOf(day);
    if (index.has(key)) continue;
    const [y, m, d] = key.split("-");
    const bucket: Bucket =
      unit === "月" ? { label: `${Number(m)}月`, title: `${y}年${Number(m)}月`, count: 0 } : unit === "周" ? { label: `${Number(m)}/${Number(d)}`, title: `${key} 起的一周`, count: 0 } : { label: `${Number(d)}`, title: key, count: 0 };
    index.set(key, bucket);
    items.push(bucket);
  }
  for (const issue of issues) {
    const at = issue.extra?.resolutiondate;
    if (!at) continue;
    const bucket = index.get(keyOf(dayString(parseTime(at))));
    if (bucket) bucket.count++;
  }
  return { unit, items };
}

/** 刻度：取 1、2、5 × 10ⁿ 中不小于最大值的整齐数。 */
function niceMax(value: number): number {
  if (value <= 4) return Math.max(1, value);
  const step = 10 ** Math.floor(Math.log10(value));
  return [1, 2, 5, 10].map((m) => m * step).find((n) => n >= value) ?? value;
}

/** 单一系列的柱状图：柱宽不超过 24px，顶部 4px 圆角，悬停显示数值，只在最高的柱子上标数值。 */
function ColumnChart({ buckets }: { buckets: Bucket[] }) {
  const ref = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(600);
  const [hover, setHover] = useState<number | null>(null);
  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const observer = new ResizeObserver(() => setWidth(el.clientWidth));
    observer.observe(el);
    setWidth(el.clientWidth);
    return () => observer.disconnect();
  }, []);

  const height = 200;
  const pad = { top: 20, right: 8, bottom: 24, left: 32 };
  const plotW = Math.max(1, width - pad.left - pad.right);
  const plotH = height - pad.top - pad.bottom;
  const max = niceMax(Math.max(...buckets.map((b) => b.count)));
  const ticks = max <= 4 ? Array.from({ length: max + 1 }, (_, i) => i) : [0, max / 2, max];
  const band = plotW / buckets.length;
  const barW = Math.min(24, Math.max(2, band * 0.6));
  const peak = buckets.reduce((best, b, i) => (b.count > buckets[best].count ? i : best), 0);
  // x 轴标签太密时隔几个显示一个
  const labelEvery = Math.ceil(buckets.length / Math.max(1, Math.floor(plotW / 36)));
  const y = (v: number) => pad.top + plotH - (v / max) * plotH;

  return (
    <div className="column-chart" ref={ref}>
      <svg width={width} height={height} role="img" aria-label="解决的问题数量">
        {ticks.map((t) => (
          <g key={t}>
            <line x1={pad.left} x2={width - pad.right} y1={y(t)} y2={y(t)} className="chart-grid" />
            <text x={pad.left - 8} y={y(t)} className="chart-tick" textAnchor="end" dominantBaseline="middle">
              {t}
            </text>
          </g>
        ))}
        {buckets.map((b, i) => {
          const x = pad.left + band * i + (band - barW) / 2;
          const h = (b.count / max) * plotH;
          const top = pad.top + plotH - h;
          const r = Math.min(4, h, barW / 2);
          return (
            <g key={b.title} onPointerEnter={() => setHover(i)} onPointerLeave={() => setHover((v) => (v === i ? null : v))}>
              {/* 命中区域为整个分段，比柱子本身大 */}
              <rect x={pad.left + band * i} y={pad.top} width={band} height={plotH} fill="transparent" />
              {h > 0 && <path d={`M${x},${pad.top + plotH} V${top + r} Q${x},${top} ${x + r},${top} H${x + barW - r} Q${x + barW},${top} ${x + barW},${top + r} V${pad.top + plotH} Z`} className={`chart-bar${hover === i ? " hover" : ""}`} />}
              {i === peak && b.count > 0 && (
                <text x={x + barW / 2} y={top - 6} className="chart-value" textAnchor="middle">
                  {b.count}
                </text>
              )}
              {i % labelEvery === 0 && (
                <text x={x + barW / 2} y={height - 6} className="chart-tick" textAnchor="middle">
                  {b.label}
                </text>
              )}
            </g>
          );
        })}
      </svg>
      {hover !== null && (
        <div className="chart-tooltip" style={{ left: Math.min(width - 140, Math.max(0, pad.left + band * hover + band / 2 - 60)), top: 0 }}>
          <strong>{buckets[hover].count} 个</strong>
          <span className="muted small">{buckets[hover].title}</span>
        </div>
      )}
    </div>
  );
}

/** 分布：横向条形，最多 8 项，其余合并为“其他”。 */
function Breakdown({ title, issues, keyOf }: { title: string; issues: IssueSummary[]; keyOf: (i: IssueSummary) => string[] }) {
  const rows = useMemo(() => {
    const counts = new Map<string, number>();
    for (const issue of issues) for (const k of keyOf(issue)) counts.set(k, (counts.get(k) ?? 0) + 1);
    const sorted = [...counts.entries()].sort((a, b) => b[1] - a[1]);
    if (sorted.length <= 8) return sorted;
    const rest = sorted.slice(7).reduce((n, [, c]) => n + c, 0);
    return [...sorted.slice(0, 7), [`其他 ${sorted.length - 7} 项`, rest] as [string, number]];
  }, [issues, keyOf]);
  const max = Math.max(1, ...rows.map(([, c]) => c));
  return (
    <div className="card breakdown">
      <h2>{title}</h2>
      {rows.length === 0 && <p className="muted small">没有数据</p>}
      <ul>
        {rows.map(([name, count]) => (
          <li key={name} title={`${name}：${count} 个`}>
            <span className="ellipsis breakdown-name">{name}</span>
            <span className="breakdown-track">
              <span className="breakdown-bar" style={{ width: `${(count / max) * 100}%` }} />
            </span>
            <span className="breakdown-count">{count}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
