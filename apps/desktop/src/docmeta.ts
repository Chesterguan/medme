// 文档类型的展示元数据 —— 时间线与详情视图共用(DRY)。
import {
  Pill,
  FlaskConical,
  ScanLine,
  Stethoscope,
  Microscope,
  BedDouble,
  FileText,
  FileQuestion,
  Scissors,
  Siren,
  ClipboardCheck,
  type LucideIcon,
} from "lucide-react";

// 就诊类型(encounter kind)—— 用户熟悉的中文,不出现 "encounter" 字样
export const KIND_LABEL: Record<string, string> = {
  inpatient: "住院",
  outpatient: "门诊",
  emergency: "急诊",
  exam: "体检",
};
export const KIND_ICON: Record<string, LucideIcon> = {
  inpatient: BedDouble,
  outpatient: Stethoscope,
  emergency: Siren,
  exam: ClipboardCheck,
};
export const KIND_TINT: Record<string, string> = {
  inpatient: "bg-indigo-50 text-indigo-700",
  outpatient: "bg-blue-50 text-blue-700",
  emergency: "bg-rose-50 text-rose-700",
  exam: "bg-emerald-50 text-emerald-700",
};

// 每个类别一个一眼可辨的图标(处方=药丸,影像=扫描,病理=显微镜…)
export const TYPE_ICON: Record<string, LucideIcon> = {
  lab_report: FlaskConical,
  imaging_report: ScanLine,
  prescription: Pill,
  discharge_summary: BedDouble,
  clinical_note: Stethoscope,
  pathology: Microscope,
  surgery: Scissors,
  other: FileText,
  unknown: FileQuestion,
};

export const TYPE_LABEL: Record<string, string> = {
  lab_report: "化验",
  imaging_report: "检查",
  discharge_summary: "出院",
  prescription: "处方",
  clinical_note: "病历",
  pathology: "病理",
  surgery: "手术",
  other: "其他",
  unknown: "未分类",
};

// 时间线卡片左侧强调边框
export const TYPE_ACCENT: Record<string, string> = {
  lab_report: "border-blue-400",
  imaging_report: "border-amber-400",
  prescription: "border-emerald-400",
  discharge_summary: "border-indigo-400",
  clinical_note: "border-sky-400",
  pathology: "border-rose-400",
  surgery: "border-purple-400",
  other: "border-slate-300",
  unknown: "border-slate-300",
};

// 类型徽标底色
export const TYPE_BADGE: Record<string, string> = {
  lab_report: "bg-blue-50 text-blue-700",
  imaging_report: "bg-amber-50 text-amber-700",
  prescription: "bg-emerald-50 text-emerald-700",
  discharge_summary: "bg-indigo-50 text-indigo-700",
  clinical_note: "bg-sky-50 text-sky-700",
  pathology: "bg-rose-50 text-rose-700",
  surgery: "bg-purple-50 text-purple-700",
  other: "bg-slate-100 text-slate-600",
  unknown: "bg-slate-100 text-slate-600",
};

export function fmtDate(d: string | null): string {
  return d ? d.slice(0, 10) : "无日期";
}

export function fmtBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}
