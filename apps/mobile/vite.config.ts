import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// @ts-expect-error process is a nodejs global
const host = process.env.TAURI_DEV_HOST;

// https://vite.dev/config/
// Tauri iOS: dev server must bind to the LAN host so the simulator/device can reach it.
export default defineConfig(async () => ({
  plugins: [react()],
  clearScreen: false,
  // iOS WKWebView 兼容:给打包产物设一个保守的 Safari 基线,确保模块能在
  // iOS 上解析。注意 safari13 会让 esbuild 因无法降级解构而报错,故用 safari14
  // 作为可构建的兼容下限(实际设备为 iOS 26,远超此基线)。
  build: {
    target: ["es2021", "safari14"],
  },
  server: {
    port: 1420,
    strictPort: true,
    // 关键:回退到 127.0.0.1(IPv4)而不是 false。false 会让 Node ≥17 把
    // localhost 解析成 IPv6 [::1] 单独绑定,而 iOS 模拟器 WebView 走 IPv4
    // 127.0.0.1 访问,导致连接被拒→WebView 白/黑屏。物理设备仍用 LAN host。
    host: host || "127.0.0.1",
    hmr: host
      ? {
          protocol: "ws",
          host,
          port: 1421,
        }
      : undefined,
    watch: {
      ignored: ["**/src-tauri/**"],
    },
  },
}));
