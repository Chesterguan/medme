import { useEffect, useState } from "react";
import {
  ArrowLeft,
  FileType2,
  ImageIcon,
  X,
  Maximize2,
  FileQuestion,
  AlertTriangle,
} from "lucide-react";
import { api } from "../api";
import type { DocumentDetail } from "../types";
import { TYPE_LABEL, TYPE_BADGE, TYPE_ICON, fmtDate, fmtBytes } from "../docmeta";
import ReportContent from "./ReportContent";
import DicomViewer from "./DicomViewer";
import ImageViewer from "./ImageViewer";
import PdfViewer from "./PdfViewer";

// 低置信度阈值:低于此值提示扫描可能不清晰/不可用,建议重拍或核对原件。
const LOW_CONFIDENCE_THRESHOLD = 0.6;
// 改版前置信度徽标分三档(amber/emerald/slate),中/高两档都上色。设计系统的色板
// 没有绿(见 ReportContent.tsx 头注释),而且中/高置信度是"符合预期"的常态 ——
// 和化验表"正常不上色"同一条道理:值得一眼看见的只有"低置信度,建议核对原件"
// 这一档(high token,与 ImportView 的"未识别到文字"同源),其余收成中性小字。

// 内容(识别文本)为主,原件作为附件:缩略图/文件条,点击全屏查看。
// OCR 已把内容读出来 → 阅读用文本,原图只在需要出示时全屏打开。
export default function DocumentView({
  detail,
  onBack,
}: {
  detail: DocumentDetail;
  onBack: () => void;
}) {
  const { document: doc, source_file: sf, ocr_text, ocr_confidence, ocr_backend } = detail;
  const [origUrl, setOrigUrl] = useState<string | null>(null);
  const [lightbox, setLightbox] = useState(false);
  // 影像检查:整叠切片的原始字节(imaging overhaul P1)。lightbox 打开时按堆栈顺序
  // 载入,关闭时释放。单张 DICOM 或无切片记录时退回该文档自身的 source。
  const [dicomSlices, setDicomSlices] = useState<Uint8Array[] | null>(null);
  // 与 dicomSlices 一一对应的 source_file id,供查看器把压缩帧交回后端解码。
  const [dicomSliceIds, setDicomSliceIds] = useState<number[] | null>(null);
  const isImage = sf.mime_type.startsWith("image/");
  const isPdf = sf.mime_type === "application/pdf";
  const isDicom = sf.mime_type === "application/dicom";
  const showAsImage = isImage || isDicom; // 缩略图:DICOM 渲染成灰度 PNG,与图片同样呈现
  const hasOriginal = showAsImage || isPdf;

  // 置信度只在真正走过 OCR(onnx/vlm)的文档上展示;native(文本层/DICOM 元数据)
  // 没有识别置信度这回事,不显示。
  const isOcrDocument = ocr_backend === "onnx" || ocr_backend === "vlm";
  const confidencePct = ocr_confidence != null ? Math.round(ocr_confidence * 100) : null;
  const isLowConfidence = isOcrDocument && ocr_confidence != null && ocr_confidence < LOW_CONFIDENCE_THRESHOLD;

  // 缩略图:DICOM 用后端渲染的静态 PNG(快),其他原样读取。
  // cancelled 标记:返回/切换文档导致组件先于 promise resolve 卸载时,既不 setState
  // 也不遗留未 revoke 的 blob URL(镜像下面 DICOM 原始字节 effect 的写法)。
  useEffect(() => {
    if (!hasOriginal) return;
    let cancelled = false;
    let url: string | null = null;
    // 缩略图取该文档自身的 source_file(影像检查 = 其锚点切片)。注意用 sf.id
    // 而非 doc.id:切片会新建无文档的 source_file,两者 id 不再一一对应。
    const bytesP = isDicom ? api.renderDicom(sf.id) : api.readSourceBytes(sf.id);
    const blobType = isDicom ? "image/png" : sf.mime_type;
    bytesP
      .then((bytes) => {
        if (cancelled) return;
        const blob = new Blob([bytes], { type: blobType });
        url = URL.createObjectURL(blob);
        setOrigUrl(url);
      })
      .catch(() => {});
    return () => {
      cancelled = true;
      if (url) URL.revokeObjectURL(url);
    };
  }, [sf.id, hasOriginal, isDicom, sf.mime_type]);

  // 全屏查看 DICOM:按需读取整叠切片的原始字节,交给 Cornerstone3D 做交互式堆栈渲染
  // (滚轮滚动 / 窗宽窗位预设 / 缩放平移 / 测量)。先取该检查的切片清单(已按堆栈顺序),逐张读取;
  // 无切片记录时退回该文档自身的 source(单张 DICOM)。
  useEffect(() => {
    if (!isDicom || !lightbox) return;
    let cancelled = false;
    (async () => {
      try {
        const insts = await api.getImagingInstances(doc.id);
        const ids =
          insts.length > 0 ? insts.map((i) => i.source_file_id) : [sf.id];
        const buffers = await Promise.all(ids.map((id) => api.readSourceBytes(id)));
        if (!cancelled) {
          setDicomSlices(buffers.map((b) => new Uint8Array(b)));
          setDicomSliceIds(ids);
        }
      } catch {
        /* 读取失败:保持 null,lightbox 显示加载态 */
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [doc.id, sf.id, isDicom, lightbox]);

  // 关闭后释放整叠字节,避免大序列常驻内存。
  useEffect(() => {
    if (!lightbox) {
      setDicomSlices(null);
      setDicomSliceIds(null);
    }
  }, [lightbox]);

  // 全屏查看时按 ESC 返回(看图软件的标准操作,避免放大后不知如何退出)
  useEffect(() => {
    if (!lightbox) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setLightbox(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [lightbox]);

  const dateStr = doc.doc_date_end
    ? `${fmtDate(doc.doc_date)} → ${fmtDate(doc.doc_date_end)}`
    : fmtDate(doc.doc_date);
  const TypeIcon = TYPE_ICON[doc.doc_type] ?? FileQuestion;

  return (
    <div className="flex-1 flex flex-col h-full overflow-hidden bg-paper">
      {/* header */}
      <div className="px-6 md:px-10 py-5 border-b border-line bg-surface/80 backdrop-blur shrink-0">
        <button
          onClick={onBack}
          className="med-focusable flex items-center gap-1.5 rounded-ctl text-body text-ink-2 hover:text-seal mb-3 cursor-pointer"
        >
          <ArrowLeft className="w-4 h-4" /> 返回
        </button>
        <div className="flex items-center gap-3 flex-wrap">
          <div
            className={`w-11 h-11 rounded-block flex items-center justify-center shrink-0 ${
              TYPE_BADGE[doc.doc_type] ?? "bg-line-2 text-ink-2"
            }`}
          >
            <TypeIcon className="w-5 h-5" />
          </div>
          <h1 className="text-display font-bold text-ink">{doc.title ?? "(无标题)"}</h1>
          <span className={`med-pill font-mono ${TYPE_BADGE[doc.doc_type] ?? "bg-line-2 text-ink-2"}`}>
            {TYPE_LABEL[doc.doc_type] ?? doc.doc_type}
          </span>
          <span className="text-secondary font-mono tabular-nums text-ink-3">{dateStr}</span>
          {doc.slice_count && doc.slice_count > 1 && (
            <span className="text-secondary font-mono tabular-nums text-ink-3">
              · {doc.slice_count} 张切片
            </span>
          )}
        </div>
        <div className="mt-2 text-caption font-mono text-ink-3 flex flex-wrap gap-x-4 gap-y-1">
          <span>原始文件:{sf.original_name}</span>
          <span>{sf.mime_type}</span>
          <span>{fmtBytes(sf.byte_size)}</span>
          <span>导入 {fmtDate(sf.imported_at)}</span>
        </div>
      </div>

      {/* 主滚动区:原件附件 + 识别文本 */}
      <div className="flex-1 overflow-y-auto p-6 md:p-10">
        <div className="max-w-3xl mx-auto space-y-6">
          {/* 原件 · 附件 */}
          {hasOriginal && (
            <div>
              <div className="text-caption font-mono text-ink-3 uppercase mb-2">原件 · 附件</div>
              {showAsImage ? (
                origUrl ? (
                  <button
                    onClick={() => setLightbox(true)}
                    className="med-focusable group relative block rounded-block overflow-hidden border border-line hover:border-seal transition-colors cursor-zoom-in bg-surface"
                  >
                    <img
                      src={origUrl}
                      alt={sf.original_name}
                      className="max-h-80 w-auto mx-auto"
                    />
                    <div className="absolute top-2 right-2 bg-black/50 text-white rounded-ctl px-2 py-1 text-xs flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
                      <Maximize2 className="w-3.5 h-3.5" /> 查看大图
                    </div>
                  </button>
                ) : (
                  <div className="text-ink-3 text-body">加载原件…</div>
                )
              ) : (
                <button
                  onClick={() => setLightbox(true)}
                  className="med-focusable flex items-center gap-3 bg-surface border border-line rounded-block px-4 py-3 hover:border-seal transition-colors cursor-pointer w-full text-left"
                >
                  <div className="w-10 h-10 rounded-ctl bg-line-2 text-ink-2 flex items-center justify-center shrink-0">
                    <FileType2 className="w-5 h-5" />
                  </div>
                  <div className="min-w-0 flex-1">
                    <div className="text-body font-medium text-ink truncate">
                      {sf.original_name}
                    </div>
                    <div className="text-caption font-mono text-ink-3">
                      PDF · {fmtBytes(sf.byte_size)} · 点击全屏查看
                    </div>
                  </div>
                  <Maximize2 className="w-4 h-4 text-ink-3 shrink-0" />
                </button>
              )}
            </div>
          )}

          {/* 识别文本 / 文档内容(主) */}
          <div>
            <div className="text-caption font-mono text-ink-3 uppercase mb-2 flex items-center gap-1.5 flex-wrap">
              {hasOriginal ? (
                <>
                  <ImageIcon className="w-3.5 h-3.5" /> 识别文本 · 可溯源
                </>
              ) : (
                "文档内容 · 原文"
              )}
              {isOcrDocument && confidencePct != null && (
                <span
                  className={
                    isLowConfidence
                      ? "med-pill normal-case tracking-normal font-sans bg-high-wash text-high"
                      : "normal-case tracking-normal font-sans text-ink-3"
                  }
                >
                  识别置信度 {confidencePct}%
                </span>
              )}
            </div>
            <div className="med-card p-6">
              {isLowConfidence && (
                <div className="mb-4 flex items-start gap-2.5 rounded-block bg-high-wash px-4 py-3 text-high">
                  <AlertTriangle className="w-5 h-5 shrink-0 mt-0.5" />
                  <div className="text-body leading-relaxed">
                    识别置信度较低({confidencePct}%),扫描可能不清晰或不可用 ——
                    建议重新拍摄,或以上方原件为准。
                  </div>
                </div>
              )}
              {ocr_text.trim() ? (
                <ReportContent text={ocr_text} docType={doc.doc_type} />
              ) : (
                <div className="text-ink-3 text-body">
                  {hasOriginal
                    ? "此文件尚未识别出文字。原始文件已完整保存(见上方附件),可直接出示给医生。"
                    : `此文件尚未识别出文字,且此格式(${sf.mime_type})无法在应用内预览。原始文件已完整、原样保存在保险箱里,可导出后用对应软件打开。`}
                </div>
              )}
            </div>
          </div>
        </div>
      </div>

      {/* 全屏查看 lightbox —— 刻意常驻纯黑背景,不跟随应用的浅色/深色主题:看图/看片
          要的是最大对比度,不是和外层 UI 统一色调(与 DicomViewer/PdfViewer/ImageViewer
          的查看器工具条同一取向)。 */}
      {lightbox && (isDicom || origUrl) && (
        <div className="fixed inset-0 z-50 bg-black/85 flex flex-col" onClick={() => setLightbox(false)}>
          <div className="relative z-10 flex justify-between items-center px-5 py-3 text-white/90 shrink-0">
            <span className="text-sm font-mono truncate">{sf.original_name}</span>
            <button
              onClick={() => setLightbox(false)}
              className="med-focusable flex items-center gap-1.5 text-sm font-medium text-white bg-white/15 hover:bg-white/25 rounded-full pl-4 pr-3 py-1.5 cursor-pointer transition-colors"
            >
              关闭 · ESC <X className="w-4 h-4" />
            </button>
          </div>
          <div
            className={
              isDicom || isImage
                ? "flex-1 min-h-0 overflow-hidden flex"
                : "flex-1 overflow-auto flex items-center justify-center p-4"
            }
          >
            {isDicom ? (
              dicomSlices ? (
                <DicomViewer
                  slices={dicomSlices}
                  sliceIds={dicomSliceIds ?? []}
                  fileName={sf.original_name}
                />
              ) : (
                <div
                  className="flex-1 flex items-center justify-center text-white/60 text-sm"
                  onClick={(e) => e.stopPropagation()}
                >
                  加载 DICOM 原始数据…
                </div>
              )
            ) : isImage ? (
              <ImageViewer src={origUrl ?? ""} alt={sf.original_name} />
            ) : origUrl ? (
              // PDF 用 PDF.js 渲染(替代 <iframe src=blob:pdf>,后者在 WKWebView 白屏)。
              <PdfViewer url={origUrl} />
            ) : null}
          </div>
        </div>
      )}
    </div>
  );
}
