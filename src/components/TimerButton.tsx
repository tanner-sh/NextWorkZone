import { Timer } from "lucide-react";
import { elapsedMs, formatClock, isTiming, requestStop, startTimer, useTimer, type TimerTarget } from "../lib/timer";

/** 开始计时；正在为这个条目计时时显示时长，点击停止并登记。 */
export function TimerButton({ target, match }: { target: TimerTarget; match: { issueKey?: string | null; todoId?: string | null } }) {
  const timer = useTimer();
  if (timer && isTiming(timer, match)) {
    return (
      <button className="btn on" onClick={() => requestStop()} title="停止计时并登记工作日志">
        <Timer size={14} />
        <span className="timer-clock">{formatClock(elapsedMs(timer))}</span>
      </button>
    );
  }
  return (
    <button className="btn" onClick={() => startTimer(target)} title={timer ? "停止当前计时并开始为这里计时" : "开始计时，停止后登记为工作日志"}>
      <Timer size={14} />
      开始计时
    </button>
  );
}
