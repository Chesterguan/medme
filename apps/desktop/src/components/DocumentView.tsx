import { useEffect, useState } from "react";
import { ArrowLeft, Image as ImageIcon, FileType2 } from "lucide-react";
import { api } from "../api";
import type { DocumentDetail } from "../types";
import { FileQuestion } from "lucide-react";
import { TYPE_LABEL, TYPE_BADGE, TYPE_ICON, fmtDate, fmtBytes } from "../docmeta";
import ReportContent from "./ReportContent";

// 模态感知的详情视图:
//  - 影像(图片)/ PDF:原件为主(病人拿给医生看的就是原图),OCR 文本为辅
//  - 纯文本文档:文本即原件,单栏专注阅读
export default function DocumentView({
  detail,
  onBack,
}: {
  detail: DocumentDetail;
  onBack: () => void;
}) {
  const { document: doc, source_file: sf, ocr_text } = detail;
  const [origUrl, setOrigUrl] = useState<string | null>(null);
  const isImage = sf.mime_type.startsWith("image/");
  const isPdf = sf.mime_type === "application/pdf";
  const hasVisualOriginal = isImage || isPdf;

  useEffect(() => {
    if (!hasVisualOriginal) return;
    let url: string | null = null;
    api
      .readSourceBytes(doc.id)
      .then((bytes) => {
        const blob = new Blob([new Uint8Array(bytes)], { type: sf.mime_type });
        url = URL.createObjectURL(blob);
        setOrigUrl(url);
      })
      .catch(() => {});
    return () => {
      if (url) URL.revokeObjectURL(url);
    };
  }, [doc.id, hasVisualOriginal, sf.mime_type]);

  const dateStr = doc.doc_date_end
    ? `${fmtDate(doc.doc_date)} → ${fmtDate(doc.doc_date_end)}`
    : fmtDate(doc.doc_date);

  const paneLabel = (
    <span className="flex items-center gap-1.5">
      {isImage ? <ImageIcon className="w-3.5 h-3.5" /> : <FileType2 className="w-3.5 h-3.5" />}
      原件 · {isImage ? "IMAGE" : "PDF"}
    </span>
  );

  return (
    <div className="flex-1 flex flex-col h-full overflow-hidden bg-slate-50">
      {/* header */}
      <div className="px-6 md:px-10 py-5 border-b border-slate-200 bg-white/80 backdrop-blur shrink-0">
        <button
          onClick={onBack}
          className="flex items-center gap-1.5 text-sm text-slate-500 hover:text-slate-900 mb-3 cursor-pointer"
        >
          <ArrowLeft className="w-4 h-4" /> 返回时间线
        </button>
        <div className="flex items-center gap-3 flex-wrap">
          {(() => {
            const Icon = TYPE_ICON[doc.doc_type] ?? FileQuestion;
            return (
              <div
                className={`w-9 h-9 rounded-lg flex items-center justify-center shrink-0 ${
                  TYPE_BADGE[doc.doc_type] ?? "bg-slate-100 text-slate-600"
                }`}
              >
                <Icon className="w-5 h-5" />
              </div>
            );
          })()}
          <h1 className="text-2xl font-bold text-slate-900">{doc.title ?? "(无标题)"}</h1>
          <span
            className={`text-xs font-mono px-2.5 py-1 rounded-full ${
              TYPE_BADGE[doc.doc_type] ?? "bg-slate-100 text-slate-600"
            }`}
          >
            {TYPE_LABEL[doc.doc_type] ?? doc.doc_type}
          </span>
          <span className="text-sm font-mono text-slate-500">{dateStr}</span>
        </div>
        <div className="mt-2 text-xs font-mono text-slate-400 flex flex-wrap gap-x-4 gap-y-1">
          <span>原始文件:{sf.original_name}</span>
          <span>{sf.mime_type}</span>
          <span>{fmtBytes(sf.byte_size)}</span>
          <span>导入 {fmtDate(sf.imported_at)}</span>
          <span>{doc.page_count} 页</span>
        </div>
      </div>

      {hasVisualOriginal ? (
        // ── 影像 / PDF:原件为主(col-span-3),OCR 文本为辅(col-span-2)──
        <div className="flex-1 overflow-hidden flex flex-col lg:grid lg:grid-cols-5">
          <section className="flex flex-col overflow-hidden lg:col-span-3 border-b lg:border-b-0 lg:border-r border-slate-200 bg-slate-100/60">
            <div className="px-6 py-2 text-[11px] font-mono text-slate-500 uppercase tracking-widest border-b border-slate-200 bg-white">
              {paneLabel}
            </div>
            <div className="flex-1 overflow-auto p-6 flex items-center justify-center min-h-[40vh]">
              {isImage && origUrl && (
                <img
                  src={origUrl}
                  alt={sf.original_name}
                  className="max-w-full max-h-full object-contain rounded-lg shadow-md border border-slate-200 bg-white"
                />
              )}
              {isPdf && origUrl && (
                <iframe
                  src={origUrl}
                  title="原件 PDF"
                  className="w-full h-full min-h-[70vh] rounded-lg border border-slate-200 bg-white"
                />
              )}
              {!origUrl && <div className="text-slate-400 text-sm">加载原件…</div>}
            </div>
          </section>
          <section className="flex flex-col overflow-hidden lg:col-span-2">
            <div className="px-6 py-2 text-[11px] font-mono text-slate-400 uppercase tracking-widest border-b border-slate-100 bg-white">
              识别文本 · 可溯源
            </div>
            <div className="flex-1 overflow-auto p-6">
              {ocr_text.trim() ? (
                <ReportContent text={ocr_text} />
              ) : (
                <div className="text-slate-400 text-sm leading-relaxed">
                  此扫描件尚未识别文字。<br />
                  原始影像已完整保存(见左侧),可直接出示给医生;文字识别将由 OCR 补齐。
                </div>
              )}
            </div>
          </section>
        </div>
      ) : (
        // ── 纯文本文档:文本即原件,单栏专注阅读 ──
        <div className="flex-1 overflow-auto p-6 md:p-10">
          <div className="max-w-3xl mx-auto">
            <div className="text-[11px] font-mono text-slate-400 uppercase tracking-widest mb-3">
              文档内容 · 原文
            </div>
            {ocr_text.trim() ? (
              <div className="bg-white rounded-2xl border border-slate-200 p-6 shadow-sm">
                <ReportContent text={ocr_text} />
              </div>
            ) : (
              <div className="text-slate-400 text-sm">此文件无文本内容。</div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
