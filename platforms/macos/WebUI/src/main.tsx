import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import AIInputApp from "./AIInputApp";
import CandidateApp from "./CandidateApp";
import SettingsApp from "./SettingsApp";
import "./styles.css";

const webViewName = window.typingChaoViewName;
document.documentElement.dataset.viewName = webViewName || "unknown";

function RootApp() {
  if (webViewName === "candidate") {
    return <CandidateApp />;
  }
  if (webViewName === "settings") {
    return <SettingsApp />;
  }
  if (webViewName === "ai-input") {
    return <AIInputApp />;
  }
  return (
    <main className="error-shell">
      <strong>Typing Chao Web UI 初始化失败</strong>
      <span>没有收到有效的页面类型，请重新安装输入法。</span>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <RootApp />
  </StrictMode>,
);
