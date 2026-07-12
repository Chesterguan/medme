import { useEffect, useRef, useState } from "react";
import * as pdfjsLib from "pdfjs-dist";
// Vite 把 worker 打成同源资产 URL(CSP: worker-src 'self')。用 PDF.js 自己把每页
// 渲染成 canvas —— 替代 <iframe src=blob:pdf>,后者在 WKWebView/安卓 WebView 里
// 渲染 blob PDF 不可靠(白屏)。这是跨平台可靠地看 PDF 的成熟方案。
import workerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";

pdfjsLib.GlobalWorkerOptions.workerSrc = workerUrl;

// 渲染倍率:2x 让中文清晰;canvas 用 CSS 缩回容器宽度。
const RENDER_SCALE = 2;

export default function PdfViewer({ url }: { url: string }) {
  const containerRef = useRef<HTMLDivElement>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let doc: any = null;
    (async () => {
      setLoading(true);
      setErr(null);
      try {
        doc = await pdfjsLib.getDocument({ url }).promise;
        if (cancelled) return;
        const container = containerRef.current;
        if (!container) return;
        container.replaceChildren();
        for (let n = 1; n <= doc.numPages; n++) {
          if (cancelled) return;
          const page = await doc.getPage(n);
          const viewport = page.getViewport({ scale: RENDER_SCALE });
          const canvas = document.createElement("canvas");
          canvas.width = viewport.width;
          canvas.height = viewport.height;
          canvas.className = "block mx-auto mb-3 bg-white rounded shadow max-w-full h-auto";
          const ctx = canvas.getContext("2d");
          if (!ctx) continue;
          await page.render({ canvasContext: ctx, viewport }).promise;
          if (cancelled) return;
          container.appendChild(canvas);
        }
      } catch (e) {
        if (!cancelled) setErr(String(e));
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();
    return () => {
      cancelled = true;
      if (doc) doc.destroy();
    };
  }, [url]);

  return (
    <div
      className="w-full h-full max-w-5xl overflow-auto"
      onClick={(e) => e.stopPropagation()}
    >
      {loading && <div className="text-white/60 text-sm p-6 text-center">加载 PDF…</div>}
      {err && (
        <div className="text-rose-300 text-sm p-6 text-center">PDF 加载失败:{err}</div>
      )}
      <div ref={containerRef} className="py-2" />
    </div>
  );
}
