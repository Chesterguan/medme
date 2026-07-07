import { useEffect, useState } from "react";
import { UploadCloud } from "lucide-react";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { api } from "../api";
import type { ImportOutcome } from "../types";

const STATUS_META: Record<string, { label: string; cls: string }> = {
  new: { label: "新增并索引", cls: "text-emerald-700 bg-emerald-50" },
  backfilled: { label: "补充索引", cls: "text-emerald-700 bg-emerald-50" },
  deduped: { label: "已存在 · 去重", cls: "text-slate-600 bg-slate-100" },
  stored_no_text: { label: "已保存 · 待 OCR", cls: "text-amber-700 bg-amber-50" },
};

export default function ImportView({ onImported }: { onImported: () => void }) {
  const [dragging, setDragging] = useState(false);
  const [busy, setBusy] = useState(false);
  const [results, setResults] = useState<ImportOutcome[]>([]);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let unlisten: (() => void) | undefined;
    getCurrentWebview()
      .onDragDropEvent((event) => {
        const p = event.payload;
        if (p.type === "enter" || p.type === "over") {
          setDragging(true);
        } else if (p.type === "leave") {
          setDragging(false);
        } else if (p.type === "drop") {
          setDragging(false);
          const paths = p.paths ?? [];
          if (paths.length) doImport(paths);
        }
      })
      .then((f) => {
        unlisten = f;
      });
    return () => {
      if (unlisten) unlisten();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const doImport = (paths: string[]) => {
    setBusy(true);
    setError(null);
    api
      .importPaths(paths)
      .then((r) => {
        setResults(r);
        onImported();
      })
      .catch((e) => setError(String(e)))
      .finally(() => setBusy(false));
  };

  return (
    <div className="flex-1 overflow-y-auto bg-slate-50 p-6 md:p-10">
      <div className="max-w-3xl mx-auto">
        <h1 className="text-2xl font-bold text-slate-900 mb-6">
          导入病历
          <span className="ml-2 text-sm font-mono text-slate-500">Import Records</span>
        </h1>

        <div
          className={`rounded-2xl border-2 border-dashed p-12 text-center transition-all ${
            dragging ? "border-blue-400 bg-blue-50" : "border-slate-300 bg-white"
          }`}
        >
          <UploadCloud
            className={`w-12 h-12 mx-auto mb-4 ${dragging ? "text-blue-500" : "text-slate-400"}`}
          />
          <div className="text-slate-700 font-medium">
            {busy ? "正在导入…" : dragging ? "松开以导入" : "把病历文件拖到这里"}
          </div>
          <div className="text-xs font-mono text-slate-400 mt-2">
            PDF · 图片(PNG / JPG / TIFF)· TXT · 原始文件永久保存,自动去重
          </div>
        </div>

        {error && <div className="mt-4 text-sm text-rose-600">导入失败:{error}</div>}

        {results.length > 0 && (
          <div className="mt-6 space-y-2">
            <div className="text-[11px] font-mono text-slate-400 uppercase tracking-widest">
              本次结果 · {results.length} 个文件
            </div>
            {results.map((r, i) => {
              const m = STATUS_META[r.status] ?? {
                label: r.status,
                cls: "text-slate-600 bg-slate-100",
              };
              return (
                <div
                  key={i}
                  className="flex items-center justify-between bg-white border border-slate-200 rounded-xl px-4 py-2.5"
                >
                  <span className="text-sm text-slate-700 truncate">{r.name}</span>
                  <span
                    className={`text-xs font-mono px-2 py-0.5 rounded-full shrink-0 ml-3 ${m.cls}`}
                  >
                    {m.label}
                  </span>
                </div>
              );
            })}
          </div>
        )}
      </div>
    </div>
  );
}
