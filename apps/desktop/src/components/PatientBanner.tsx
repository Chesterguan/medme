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
    // 这条 banner **刻意不带骑缝线** —— 姓名/性别/年龄是从各记录里归纳出来的派生
    // 数据,背后没有某一张可点开的原件。骑缝线只留给「点得进去」的卡。
    <div className="px-6 md:px-10 py-4 border-b border-line bg-surface flex items-center gap-4 shrink-0">
      <div className="w-12 h-12 rounded-full bg-seal-wash border border-line flex items-center justify-center text-seal shrink-0">
        <UserRound className="w-7 h-7" />
      </div>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2.5 flex-wrap">
          <span className="text-title font-bold text-ink">{p.name ?? "未识别姓名"}</span>
          {p.gender && <span className="med-pill bg-line-2 text-ink-2">{p.gender}</span>}
          {p.age && (
            <span className="med-pill font-mono bg-line-2 text-ink-2">约 {p.age} 岁</span>
          )}
          {p.birth_date && (
            <span className="text-secondary font-mono tabular-nums text-ink-3">
              生于 {p.birth_date}
            </span>
          )}
        </div>
        <span className="text-secondary text-ink-3">
          个人健康数据保险箱 · 身份信息由各记录自动归纳
        </span>
      </div>
      <div className="flex items-center gap-1.5 text-ink-2 text-secondary font-mono tabular-nums shrink-0">
        <FileText className="w-4 h-4 text-ink-3" /> {p.record_count} 份记录
      </div>
    </div>
  );
}
