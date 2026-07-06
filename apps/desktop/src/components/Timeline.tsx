import type { DocumentSummary } from "../types";

const TYPE_LABEL: Record<string, string> = {
  lab_report: "化验", imaging_report: "检查", discharge_summary: "出院",
  prescription: "处方", clinical_note: "病历", pathology: "病理",
  other: "其他", unknown: "未分类",
};
const TYPE_ACCENT: Record<string, string> = {
  lab_report: "border-blue-400", imaging_report: "border-amber-400",
  prescription: "border-emerald-400", discharge_summary: "border-indigo-400",
};

function fmtDate(d: string | null): string {
  if (!d) return "无日期";
  return d.slice(0, 10);
}

export default function Timeline({ docs }: { docs: DocumentSummary[] }) {
  if (docs.length === 0) {
    return (
      <div className="flex-1 flex items-center justify-center text-slate-400 text-sm">
        还没有记录。导入病历后,这里会按时间显示你的生命时间线。
      </div>
    );
  }
  return (
    <div className="flex-1 overflow-y-auto bg-slate-50 p-8">
      <div className="max-w-3xl mx-auto space-y-3">
        <h1 className="text-lg font-bold text-slate-900 mb-4">生命时间线
          <span className="ml-2 text-xs font-mono text-slate-500">{docs.length} 份</span>
        </h1>
        {docs.map((d) => (
          <div key={d.id}
               className={`bg-white border border-slate-200 border-l-4 ${TYPE_ACCENT[d.doc_type] ?? "border-slate-300"} rounded-2xl p-4 shadow-sm hover:shadow-md transition-all`}>
            <div className="flex items-center justify-between">
              <span className="font-medium text-slate-800">{d.title ?? "(无标题)"}</span>
              <span className="text-xs font-mono text-slate-500">{fmtDate(d.doc_date)}</span>
            </div>
            <span className="text-[11px] font-mono px-2 py-0.5 rounded bg-slate-100 text-slate-600 mt-1 inline-block">
              {TYPE_LABEL[d.doc_type] ?? d.doc_type}
            </span>
          </div>
        ))}
      </div>
    </div>
  );
}
