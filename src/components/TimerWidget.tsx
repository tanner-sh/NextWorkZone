import { useEffect, useState } from "react";
import { Pause, Play, Square, Timer } from "lucide-react";
import { api, errorMessage, type IssueChoice } from "../api";
import { clearTimer, currentTimer, elapsedMs, formatClock, jiraDuration, onStopRequest, pauseTimer, requestStop, resumeTimer, startTimer, useTimer, type TimerState, type TimerTarget } from "../lib/timer";
import { useNav } from "../state/nav";
import { useSettings } from "../state/settings";
import { Picker, toJiraDateTime } from "../pages/jira/fieldForm";
import { ErrorBox, Modal } from "./common";
import { toast } from "./Toast";

/** 侧边栏中正在进行的计时，以及停止后登记工作日志的对话框。 */
export function TimerWidget() {
  const timer = useTimer();
  const { navigate } = useNav();
  /** `wasRunning`：打开对话框前是否在计时（选“继续计时”时恢复原状态） */
  const [stopping, setStopping] = useState<{ state: TimerState; next: TimerTarget | null; wasRunning: boolean } | null>(null);

  useEffect(
    () =>
      onStopRequest((next) => {
        const state = currentTimer();
        if (!state) return;
        // 打开对话框时暂停，避免填写期间继续计时
        const wasRunning = Boolean(state.runningSince);
        pauseTimer();
        setStopping({ state: currentTimer() ?? state, next, wasRunning });
      }),
    [],
  );

  const finish = (next: TimerTarget | null) => {
    clearTimer();
    setStopping(null);
    if (next) startTimer(next);
  };

  return (
    <>
      {timer && (
        <div className={`timer-widget${timer.runningSince ? " running" : ""}`}>
          <button
            className="timer-target"
            title="打开计时的条目"
            onClick={() => (timer.target.todoId ? navigate({ page: "todos", todoId: timer.target.todoId }) : timer.target.issueKey && navigate({ page: "jira", issueKey: timer.target.issueKey }))}
          >
            <Timer size={14} />
            <span className="timer-clock">{formatClock(elapsedMs(timer))}</span>
            <span className="ellipsis timer-title">{timer.target.issueKey ?? timer.target.title}</span>
          </button>
          {timer.runningSince ? (
            <button className="btn subtle icon" title="暂停" onClick={pauseTimer}>
              <Pause size={13} />
            </button>
          ) : (
            <button className="btn subtle icon" title="继续" onClick={resumeTimer}>
              <Play size={13} />
            </button>
          )}
          <button className="btn subtle icon" title="停止并登记工作日志" onClick={() => requestStop()}>
            <Square size={13} />
          </button>
        </div>
      )}
      {stopping && (
        <LogWorkDialog
          state={stopping.state}
          next={stopping.next}
          onContinue={() => {
            if (stopping.wasRunning) resumeTimer();
            setStopping(null);
          }}
          onDone={() => finish(stopping.next)}
        />
      )}
    </>
  );
}

function LogWorkDialog({ state, next, onContinue, onDone }: { state: TimerState; next: TimerTarget | null; onContinue: () => void; onDone: () => void }) {
  const { isReady } = useSettings();
  const target = state.target;
  const [issue, setIssue] = useState<IssueChoice | null>(target.issueKey ? { key: target.issueKey, summary: target.issueSummary ?? (target.todoId ? "" : target.title) } : null);
  const [choosing, setChoosing] = useState(!target.issueKey);
  const [started, setStarted] = useState(localInput(state.firstStartedAt));
  const [timeSpent, setTimeSpent] = useState(jiraDuration(elapsedMs(state)));
  const [comment, setComment] = useState(state.target.todoId ? state.target.title : "");
  const [saving, setSaving] = useState(false);
  const [confirmDiscard, setConfirmDiscard] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const log = async () => {
    if (!issue) return;
    setSaving(true);
    setError(null);
    try {
      await api.jiraSaveWorklog(issue.key, null, { started: toJiraDateTime(started), timeSpent: timeSpent.trim(), comment: comment.trim() });
      toast(`已在 ${issue.key} 登记 ${timeSpent.trim()}`);
      onDone();
    } catch (e) {
      setError(errorMessage(e));
      setSaving(false);
    }
  };

  return (
    <Modal
      title="停止计时"
      onClose={onContinue}
      dirty={saving}
      footer={
        <>
          {confirmDiscard ? (
            <span className="inline-confirm">
              <button className="btn danger small-btn" onClick={onDone}>
                确认放弃
              </button>
              <button className="btn small-btn" onClick={() => setConfirmDiscard(false)}>
                取消
              </button>
            </span>
          ) : (
            <button className="btn subtle" onClick={() => setConfirmDiscard(true)}>
              不登记
            </button>
          )}
          <span className="spacer" />
          <button className="btn" onClick={onContinue}>
            继续计时
          </button>
          <button className="btn primary" disabled={!issue || !timeSpent.trim() || !started || saving || !isReady("jira")} onClick={log}>
            {saving ? "登记中…" : "登记工作日志"}
          </button>
        </>
      }
    >
      <p className="muted small">
        {state.target.title} · 共计时 {formatClock(elapsedMs(state))}
        {next && `。登记后开始为「${next.issueKey ?? next.title}」计时`}
      </p>
      <div className="form-field">
        <span>登记到问题</span>
        {issue && !choosing ? (
          <span className="linked-issue">
            <strong>{issue.key}</strong>
            <span className="ellipsis">{issue.summary}</span>
            <button className="btn subtle small-btn" onClick={() => setChoosing(true)}>
              更换
            </button>
          </span>
        ) : (
          <Picker<IssueChoice>
            selected={issue ? [issue] : []}
            onChange={(list) => setIssue(list[0] ?? null)}
            search={async (q) => (q.trim() ? (await api.jiraPickIssues(q, null, false)).map((i) => ({ key: i.key, summary: i.summary })) : [])}
            label={(c) => (c.summary ? `${c.key} ${c.summary}` : c.key)}
            id={(c) => c.key}
            placeholder="输入问题键或概要搜索"
          />
        )}
      </div>
      <div className="form-grid">
        <label className="form-field">
          <span>开始时间</span>
          <input type="datetime-local" value={started} onChange={(e) => setStarted(e.target.value)} />
        </label>
        <label className="form-field">
          <span>耗时</span>
          <input value={timeSpent} onChange={(e) => setTimeSpent(e.target.value)} placeholder="例如 1h 30m" />
        </label>
      </div>
      <label className="form-field">
        <span>工作说明（可选）</span>
        <textarea rows={3} value={comment} onChange={(e) => setComment(e.target.value)} />
      </label>
      {error && <ErrorBox message={error} />}
    </Modal>
  );
}

/** datetime-local 输入框的值，例如 2026-10-23T09:30 */
function localInput(ms: number): string {
  const d = new Date(ms);
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}
