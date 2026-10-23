import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";
import { BasicMenuHost } from "./components/MenuHost";
import { CaptureWindow } from "./pages/workspace/CaptureWindow";
import { ClipPanel } from "./pages/tools/clipboard/ClipPanel";
import "./styles.css";

// macOS 上窗口透明，侧边栏显示系统材质（见 tauri.conf.json 的 windowEffects）
if (navigator.userAgent.includes("Mac")) document.documentElement.classList.add("mac");

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

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    {capture ? (
      <BasicMenuHost>
        <CaptureWindow />
      </BasicMenuHost>
    ) : clipboard ? (
      <BasicMenuHost>
        <ClipPanel />
      </BasicMenuHost>
    ) : (
      <App />
    )}
  </StrictMode>,
);
