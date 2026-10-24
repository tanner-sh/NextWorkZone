import { StrictMode, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import "./styles.css";

// 改名前的本地设置（已保存的查询、周报草稿等）迁移到新前缀，只执行一次
try {
  for (const key of Object.keys(localStorage)) {
    if (!key.startsWith("mywork.")) continue;
    const next = "nextworkzone." + key.slice("mywork.".length);
    if (localStorage.getItem(next) === null) localStorage.setItem(next, localStorage.getItem(key)!);
    localStorage.removeItem(key);
  }
} catch {
  // 存储不可用时忽略
}

// 快速记录窗口、剪贴板面板与主窗口共用同一份前端，按地址中的 #capture、#clipboard 区分
const capture = location.hash === "#capture";
const clipboard = location.hash === "#clipboard";
if (capture) document.documentElement.classList.add("capture-window");
if (clipboard) document.documentElement.classList.add("clip-window");

// 每个窗口只加载自己的代码：快速记录和剪贴板面板常驻后台，不必解析整个主界面
const load: Promise<ReactNode> = capture
  ? Promise.all([import("./components/menuTargets"), import("./pages/workspace/CaptureWindow")]).then(([{ BasicMenuHost }, { CaptureWindow }]) => (
      <BasicMenuHost>
        <CaptureWindow />
      </BasicMenuHost>
    ))
  : clipboard
    ? Promise.all([import("./components/menuTargets"), import("./pages/tools/clipboard/ClipPanel")]).then(([{ BasicMenuHost }, { ClipPanel }]) => (
        <BasicMenuHost>
          <ClipPanel />
        </BasicMenuHost>
      ))
    : import("./App").then(({ App }) => <App />);

void load.then((ui) => createRoot(document.getElementById("root")!).render(<StrictMode>{ui}</StrictMode>));
