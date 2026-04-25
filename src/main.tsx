import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import "./index.css";

interface ErrorBoundaryState {
  hasError: boolean;
  error: Error | null;
}

class ErrorBoundary extends React.Component<
  { children: React.ReactNode },
  ErrorBoundaryState
> {
  state: ErrorBoundaryState = { hasError: false, error: null };

  static getDerivedStateFromError(error: Error) {
    return { hasError: true, error };
  }

  componentDidCatch(error: Error, info: React.ErrorInfo) {
    console.error("React render error:", error, info.componentStack);
  }

  render() {
    if (this.state.hasError) {
      return (
        <div style={{ padding: 24, color: "#f7768e", fontFamily: "monospace" }}>
          <h2>渲染错误</h2>
          <pre style={{ marginTop: 8, whiteSpace: "pre-wrap" }}>
            {this.state.error?.toString()}
          </pre>
          <button
            style={{
              marginTop: 16,
              padding: "8px 16px",
              background: "#7aa2f7",
              color: "#1a1b26",
              border: "none",
              borderRadius: 4,
              cursor: "pointer",
            }}
            onClick={() => this.setState({ hasError: false, error: null })}
          >
            重试
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <ErrorBoundary>
      <App />
    </ErrorBoundary>
  </React.StrictMode>
);
