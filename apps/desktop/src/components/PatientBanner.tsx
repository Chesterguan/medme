import { useEffect, useState } from "react";
import { UserRound, FileText } from "lucide-react";
import { api } from "../api";
import type { PatientProfile } from "../types";

// 病人身份 banner —— 顶部常驻共享区。身份(姓名/性别)在各记录中一致,
// 只在此显示一次;年龄随就诊时间变化,取众数为近似。
export default function PatientBanner({ reloadKey = 0 }: { reloadKey?: number }) {
  const [p, setP] = useState<PatientProfile | null>(null);

  useEffect(() => {
    api.getPatientProfile().then(setP).catch(() => {});
  }, [reloadKey]);

  if (!p) return null;

  return (
    <div className="px-6 md:px-10 py-4 border-b border-slate-200 bg-white flex items-center gap-4 shrink-0">
      <div className="w-12 h-12 rounded-full bg-blue-50 border border-blue-100 flex items-center justify-center text-blue-600 shrink-0">
        <UserRound className="w-7 h-7" />
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2.5 flex-wrap">
          <span className="text-lg font-bold text-slate-900">{p.name ?? "未识别姓名"}</span>
          {p.gender && (
            <span className="text-xs font-mono px-2 py-0.5 rounded-full bg-slate-100 text-slate-600">
              {p.gender}
            </span>
          )}
          {p.age && (
            <span className="text-xs font-mono px-2 py-0.5 rounded-full bg-slate-100 text-slate-600">
              约 {p.age} 岁
            </span>
          )}
          {p.birth_date && (
            <span className="text-xs font-mono text-slate-400">生于 {p.birth_date}</span>
          )}
        </div>
        <span className="text-[11px] font-mono text-slate-400 tracking-wide">
          个人健康数据保险箱 · 身份信息由各记录自动归纳
        </span>
      </div>
      <div className="flex items-center gap-1.5 text-slate-400 text-sm font-mono shrink-0">
        <FileText className="w-4 h-4" /> {p.record_count} 份记录
      </div>
    </div>
  );
}
