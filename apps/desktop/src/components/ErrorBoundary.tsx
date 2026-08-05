import { Component, type ErrorInfo, type ReactNode } from "react";
import { AlertTriangle, RotateCcw } from "lucide-react";

// 顶层错误边界:渲染/生命周期阶段的同步抛错(最容易触发的是 Cornerstone3D
// 的初始化 / setStack,见 DicomViewer.tsx)否则会把整个应用白屏。
// 捕获后展示一个可恢复的简单提示,而不是让用户面对空白页面。

interface Props {
  children: ReactNode;
}

interface State {
  hasError: boolean;
}

export default class ErrorBoundary extends Component<Props, State> {
  state: State = { hasError: false };

  static getDerivedStateFromError(): State {
    return { hasError: true };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("[ErrorBoundary] 捕获到渲染错误", error, info);
  }

  handleReload = () => {
    this.setState({ hasError: false });
    window.location.reload();
  };

  render() {
    if (this.state.hasError) {
      return (
        <div className="flex-1 h-full w-full flex flex-col items-center justify-center gap-4 bg-paper text-center px-6">
          {/* 出了错 → critical 一档(化验危急值同源),与 App.tsx 里加载失败的红同一个红。 */}
          <div className="w-12 h-12 rounded-block bg-critical-wash text-critical flex items-center justify-center border border-line">
            <AlertTriangle className="w-6 h-6" />
          </div>
          <div className="text-body font-medium text-ink">出了点问题,请重试</div>
          <button onClick={this.handleReload} className="med-btn med-btn-1 med-focusable">
            <RotateCcw className="w-4 h-4" /> 重新加载
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}
