import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri 开发模式会连接固定端口，见 src-tauri/tauri.conf.json 的 devUrl。
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  // 预先声明依赖，避免开发时运行中途重新预构建导致页面里出现两份 React
  optimizeDeps: {
    include: [
      "react",
      "react-dom/client",
      "dompurify",
      "highlight.js/lib/common",
      "@tauri-apps/api/core",
      "@tauri-apps/api/event",
      "@tauri-apps/api/webview",
      "@tauri-apps/plugin-dialog",
      "@tauri-apps/plugin-notification",
      "@tauri-apps/plugin-opener",
    ],
  },
  server: {
    port: 1420,
    strictPort: true,
    watch: { ignored: ["**/src-tauri/**", "**/crates/**", "**/target/**"] },
  },
});
