import { useState } from "react";
import {
  ChevronDown,
  ChevronRight,
  FileQuestion,
  Stethoscope,
  ArrowLeftRight,
  Sparkles,
  Loader2,
} from "lucide-react";
import type { TimelineGroup, DocumentSummary, EncounterSummary } from "../types";
import {
  TYPE_LABEL,
  TYPE_BADGE,
  TYPE_ICON,
  KIND_LABEL,
  KIND_ICON,
  KIND_TINT,
  fmtDate,
} from "../docmeta";

function docDateStr(d: DocumentSummary): string {
  return d.doc_date_end
    ? `${fmtDate(d.doc_date)} → ${fmtDate(d.doc_date_end)}`
    : fmtDate(d.doc_date);
}

// 独立文档:大卡片(与就诊组同层级)
//
// 这张卡**带骑缝线** —— 点它就打开那份原件,符合「背后有原件、点得进去」。
// 改版前它靠左侧 4px 彩色竖条(TYPE_ACCENT,七种颜色)标类型;竖条这个语汇在
// 设计系统里是留给化验状态(偏低/偏高/危急值)的,占着会撞语义,所以撤掉,
// 类型改由图标 + 徽标承担 —— 信息没少,颜色少了六种。
function DocCard({ d, onSelect }: { d: DocumentSummary; onSelect: (id: number) => void }) {
  const Icon = TYPE_ICON[d.doc_type] ?? FileQuestion;
  return (
    <button
      onClick={() => onSelect(d.id)}
      className="med-card med-perf med-focusable w-full text-left px-5 pb-5 pt-6 hover:border-seal transition-colors cursor-pointer group"
    >
      <div className="flex items-center gap-4">
        <div
          className={`w-11 h-11 rounded-block flex items-center justify-center shrink-0 ${
            TYPE_BADGE[d.doc_type] ?? "bg-line-2 text-ink-2"
          }`}
        >
          <Icon className="w-5 h-5" />
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex items-start justify-between gap-4">
            <span className="text-subtitle font-semibold text-ink group-hover:text-seal-ink transition-colors truncate">
              {d.title ?? "(无标题)"}
            </span>
            <span className="text-secondary font-mono tabular-nums text-ink-3 shrink-0 pt-1">
              {docDateStr(d)}
            </span>
          </div>
          <div className="flex items-center gap-2 mt-1.5">
            <span className={`med-pill ${TYPE_BADGE[d.doc_type] ?? "bg-line-2 text-ink-2"}`}>
              {TYPE_LABEL[d.doc_type] ?? d.doc_type}
            </span>
            {d.slice_count && d.slice_count > 1 && (
              <span className="text-secondary font-mono tabular-nums text-ink-3">
                · {d.slice_count} 张切片
              </span>
            )}
          </div>
        </div>
      </div>
    </button>
  );
}

// 就诊组内的文档行:紧凑
function DocRow({ d, onSelect }: { d: DocumentSummary; onSelect: (id: number) => void }) {
  const Icon = TYPE_ICON[d.doc_type] ?? FileQuestion;
  return (
    <button
      onClick={() => onSelect(d.id)}
      className="med-focusable w-full text-left flex items-center gap-3 px-3 py-2 rounded-ctl hover:bg-surface transition-colors cursor-pointer group"
    >
      <div
        className={`w-8 h-8 rounded-ctl flex items-center justify-center shrink-0 ${
          TYPE_BADGE[d.doc_type] ?? "bg-line-2 text-ink-2"
        }`}
      >
        <Icon className="w-4 h-4" />
      </div>
      <span className="text-body text-ink group-hover:text-seal-ink truncate flex-1">
        {d.title ?? "(无标题)"}
      </span>
      {/* 改版前是 text-[11px],低于 007 §2.5 的 12px 下限 —— 提到 caption 一档 */}
      <span className="text-caption font-mono text-ink-3 shrink-0">
        {TYPE_LABEL[d.doc_type] ?? d.doc_type}
      </span>
      {/* 日期成列右对齐 → 必须等宽,否则每行的「2016」宽度都不一样 */}
      <span className="text-secondary font-mono tabular-nums text-ink-3 shrink-0 w-24 text-right">
        {fmtDate(d.doc_date)}
      </span>
    </button>
  );
}

// 就诊组:可展开
function EncounterCard({
  enc,
  docs,
  onSelect,
}: {
  enc: EncounterSummary;
  docs: DocumentSummary[];
  onSelect: (id: number) => void;
}) {
  const [open, setOpen] = useState(false);
  const KindIcon = KIND_ICON[enc.kind] ?? Stethoscope;
  const dateStr = enc.end_date
    ? `${fmtDate(enc.start_date)} → ${fmtDate(enc.end_date)}`
    : fmtDate(enc.start_date);
  return (
    // 就诊卡**不带骑缝线**:「一次就诊」是分组算出来的,点它是展开而不是打开
    // 某一张原件。原件在展开后的每一行里,一键可达。
    <div className="med-card overflow-hidden">
      <button
        onClick={() => setOpen((o) => !o)}
        className="med-focusable w-full text-left flex items-center gap-4 p-5 hover:bg-paper transition-colors cursor-pointer"
      >
        {open ? (
          <ChevronDown className="w-5 h-5 text-ink-3 shrink-0" />
        ) : (
          <ChevronRight className="w-5 h-5 text-ink-3 shrink-0" />
        )}
        <div
          className={`w-11 h-11 rounded-block flex items-center justify-center shrink-0 ${
            KIND_TINT[enc.kind] ?? "bg-line-2 text-ink-2"
          }`}
        >
          <KindIcon className="w-5 h-5" />
        </div>
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2 flex-wrap">
            <span className="text-subtitle font-semibold text-ink">
              {KIND_LABEL[enc.kind] ?? enc.kind}
            </span>
            {enc.provider && <span className="text-body text-ink-2">· {enc.provider}</span>}
            {enc.transferred && (
              // 改版前是 amber(#B45309 那一族)。设计系统把这一族**定死给「偏高」**,
              // 借来标转院会稀释化验状态色的语义 —— 转院是事实不是异常,收成中性。
              <span className="med-pill bg-line-2 text-ink-2">
                <ArrowLeftRight className="w-3.5 h-3.5" />
                转院
              </span>
            )}
          </div>
          <span className="text-secondary font-mono tabular-nums text-ink-3">
            {enc.doc_count} 份记录
          </span>
        </div>
        <span className="text-secondary font-mono tabular-nums text-ink-3 shrink-0">{dateStr}</span>
      </button>
      {open && (
        <div className="border-t border-line-2 p-2 space-y-0.5 bg-paper">
          {docs.map((d) => (
            <DocRow key={d.id} d={d} onSelect={onSelect} />
          ))}
        </div>
      )}
    </div>
  );
}

export default function Timeline({
  groups,
  onSelect,
  onLoadDemo,
  loadingDemo,
  demoError,
}: {
  groups: TimelineGroup[];
  onSelect: (id: number) => void;
  /** 空状态下「加载示例数据」入口(见 App.tsx);未传则不显示该按钮。 */
  onLoadDemo?: () => void;
  loadingDemo?: boolean;
  demoError?: string | null;
}) {
  if (groups.length === 0) {
    // 空态必须给出路 —— 虚线框在说「这里本该有东西」,框里就是那条出路。
    // 改版前:一行灰字 + 一颗紫色(violet-600,不在色板里)按钮浮在留白正中。
    return (
      <div className="flex-1 overflow-y-auto bg-paper p-6 md:p-10">
        <div className="max-w-4xl mx-auto">
          <h1 className="text-display font-bold text-ink mb-6">生命时间线</h1>
          <div className="med-empty">
            <p className="text-body text-ink-2 mb-4">
              保险箱里还没有记录 —— 点下面一键试用,或到「导入 · 导出」页拖入你的病历。
            </p>
            {onLoadDemo && (
              <>
                {/* 这一屏唯一的主按钮:纯色 seal,不用渐变 */}
                <button
                  type="button"
                  onClick={onLoadDemo}
                  disabled={loadingDemo}
                  className="med-btn med-btn-1 med-focusable"
                >
                  {loadingDemo ? (
                    <Loader2 className="w-4 h-4 animate-spin" />
                  ) : (
                    <Sparkles className="w-4 h-4" />
                  )}
                  {loadingDemo ? "加载中…" : "加载示例数据(张建国)"}
                </button>
                <p className="text-secondary text-ink-3 mt-3">示例数据,可随时删除保险箱重来</p>
                {demoError && (
                  <p className="text-body text-critical mt-3 max-w-md mx-auto break-all">
                    {demoError}
                  </p>
                )}
              </>
            )}
          </div>
        </div>
      </div>
    );
  }
  const total = groups.reduce(
    (n, g) => n + (g.group_type === "encounter" ? g.encounter.doc_count : 1),
    0,
  );
  const visits = groups.filter((g) => g.group_type === "encounter").length;
  return (
    <div className="flex-1 overflow-y-auto bg-paper p-6 md:p-10">
      <div className="max-w-4xl mx-auto space-y-3">
        <h1 className="text-display font-bold text-ink mb-6 flex items-baseline gap-3 flex-wrap">
          生命时间线
          <span className="text-secondary font-mono tabular-nums text-ink-3 font-normal">
            {total} 份 · {visits} 次就诊
          </span>
        </h1>
        {groups.map((g) => {
          if (g.group_type === "document") {
            return <DocCard key={`d${g.doc.id}`} d={g.doc} onSelect={onSelect} />;
          }
          // 单文档就诊 → 直接显示那份文档(别用折叠组把真报告藏起来);
          // 只有多文档就诊(住院等)才折叠成可展开的就诊卡。
          if (g.docs.length <= 1) {
            const d = g.docs[0];
            return d ? <DocCard key={`e1${g.encounter.id}`} d={d} onSelect={onSelect} /> : null;
          }
          return (
            <EncounterCard
              key={`e${g.encounter.id}`}
              enc={g.encounter}
              docs={g.docs}
              onSelect={onSelect}
            />
          );
        })}
      </div>
    </div>
  );
}
