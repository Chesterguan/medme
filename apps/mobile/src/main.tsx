import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./styles.css";

// 根级错误边界:任何渲染期/加载期异常都以可读文字显示在浅色背景上,
// 绝不再退回黑屏。iOS WKWebView 上一旦 JS 抛错而无边界,页面不绘制即黑屏。
type EBState = { error: Error | null; info: string | null };
class RootErrorBoundary extends React.Component<
  { children: React.ReactNode },
  EBState
> {
  state: EBState = { error: null, info: null };
  static getDerivedStateFromError(error: Error): Partial<EBState> {
    return { error };
  }
  componentDidCatch(error: Error, info: React.ErrorInfo) {
    this.setState({ error, info: info.componentStack ?? null });
  }
  render() {
    if (this.state.error) {
      return (
        <div
          style={{
            minHeight: "100vh",
            background: "#f6f8fb",
            color: "#0f172a",
            padding: "24px 16px",
            font: "14px/1.5 -apple-system, system-ui, sans-serif",
            WebkitOverflowScrolling: "touch",
            overflow: "auto",
          }}
        >
          <h2 style={{ color: "#b91c1c", marginBottom: 12 }}>应用启动出错</h2>
          <pre
            style={{
              whiteSpace: "pre-wrap",
              wordBreak: "break-word",
              background: "#fff",
              border: "1px solid #e5e9f0",
              borderRadius: 10,
              padding: 12,
              fontSize: 12,
            }}
          >
            {String(this.state.error?.stack || this.state.error?.message || this.state.error)}
            {this.state.info ? "\n\n" + this.state.info : ""}
          </pre>
        </div>
      );
    }
    return this.props.children;
  }
}

const rootEl = document.getElementById("root");
if (rootEl) {
  ReactDOM.createRoot(rootEl).render(
    <React.StrictMode>
      <RootErrorBoundary>
        <App />
      </RootErrorBoundary>
    </React.StrictMode>,
  );
}

// 兜底:模块加载/求值阶段(React 尚未挂载)的异常,也直接绘制到页面,
// 避免黑屏无信息。
function paintFatal(msg: string) {
  const el = document.getElementById("root");
  if (!el) return;
  el.innerHTML =
    '<div style="min-height:100vh;background:#f6f8fb;color:#0f172a;padding:24px 16px;' +
    'font:14px/1.5 -apple-system,system-ui,sans-serif;overflow:auto">' +
    '<h2 style="color:#b91c1c;margin-bottom:12px">启动脚本异常</h2>' +
    '<pre style="white-space:pre-wrap;word-break:break-word;background:#fff;' +
    'border:1px solid #e5e9f0;border-radius:10px;padding:12px;font-size:12px">' +
    msg.replace(/</g, "&lt;") +
    "</pre></div>";
}
window.addEventListener("error", (e) =>
  paintFatal((e.error && (e.error.stack || e.error.message)) || e.message || String(e)),
);
window.addEventListener("unhandledrejection", (e) =>
  paintFatal("Unhandled promise rejection:\n" + String((e as PromiseRejectionEvent).reason)),
);
