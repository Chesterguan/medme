import { useEffect, useState } from "react";
import { ShieldAlert, ArrowLeft, Copy, Check, FileDown } from "lucide-react";
import { api } from "../api";
import type { AuditEntry } from "../types";

// 改版前是 emerald / blue / amber 三族。收敛进色板:进保险箱是常态(中性),
// 出保险箱用主色,分享给外人是**数据离开过设备**、审计时最该一眼看见的一行,
// 给「注意」那一档(见 App.css 里关于 high/critical 推广用法的说明)。
const ACTION_BADGE: Record<string, string> = {
  导入: "bg-line-2 text-ink-2",
  导出: "bg-seal-wash text-seal-ink",
  分享: "bg-high-wash text-high",
};

function fmtTs(ts: string): string {
  // RFC3339 → 本地可读时间,解析失败时原样展示。
  const d = new Date(ts);
  return Number.isNaN(d.getTime()) ? ts : d.toLocaleString();
}

function shortHash(h: string | null): string {
  if (!h) return "—";
  return h.length > 16 ? `${h.slice(0, 8)}…${h.slice(-6)}` : h;
}

export default function AuditView({ onNav }: { onNav: (id: string) => void }) {
  const [entries, setEntries] = useState<AuditEntry[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [copiedSeq, setCopiedSeq] = useState<number | null>(null);

  useEffect(() => {
    api.getAuditLog().then(setEntries).catch((e) => setError(String(e)));
  }, []);

  const copyHash = async (seq: number, hash: string) => {
    try {
      await navigator.clipboard.writeText(hash);
      setCopiedSeq(seq);
      setTimeout(() => setCopiedSeq(null), 1500);
    } catch {
      /* 剪贴板不可用时忽略 */
    }
  };

  // 导出审计清单 CSV:内容在此按不可变事件日志生成,由后端写入固定的导出目录并返回
  // 路径。安全:不再由 webview 指定写入路径(旧 write_text_file 可被滥用为任意写)。
  const exportManifest = async () => {
    setError(null);
    setNotice(null);
    const header = "seq,timestamp,device_id,action,detail,sha256\n";
    const rows = entries
      .map((e) =>
        [e.seq, e.timestamp, e.device_id, e.action, e.detail, e.sha256 ?? ""]
          .map((v) => `"${String(v).replace(/"/g, '""')}"`)
          .join(","),
      )
      .join("\n");
    try {
      const path = await api.exportAuditCsv(header + rows);
      setNotice(`已导出到:${path}`);
    } catch (e) {
      setError(String(e));
    }
  };

  return (
    <div className="flex-1 overflow-y-auto bg-paper p-6 md:p-10">
      <div className="max-w-4xl mx-auto space-y-5">
        <button
          type="button"
          onClick={() => onNav("timeline")}
          className="med-focusable flex items-center gap-1.5 rounded-ctl text-body text-ink-2 hover:text-seal cursor-pointer"
        >
          <ArrowLeft className="w-4 h-4" /> 返回时间线
        </button>

        <div className="flex items-center gap-3">
          <div className="w-11 h-11 rounded-block bg-high-wash flex items-center justify-center text-high border border-line shrink-0">
            <ShieldAlert className="w-6 h-6" />
          </div>
          <div>
            <h1 className="text-display font-bold text-ink">审计追踪</h1>
            {/* 改版前 text-[11px],低于 12px 下限 */}
            <span className="text-caption font-mono text-ink-3 uppercase">
              Audit Trail · Hidden
            </span>
          </div>
        </div>

        {/* 这是说明不是警告 → 收成中性分块,不再整条刷成琥珀色 */}
        <div className="med-block px-4 py-3 text-body text-ink-2">
          审计追踪:所有导入/导出/分享均由不可变事件日志记录(含内容哈希 sha256),可核验、防篡改。
        </div>

        {error && (
          <div className="rounded-block px-4 py-2.5 text-body bg-critical-wash text-critical">
            {error}
          </div>
        )}

        {notice && (
          <div className="rounded-block px-4 py-2.5 text-body bg-seal-wash text-seal-ink break-all">
            {notice}
          </div>
        )}

        <div className="flex justify-end">
          <button
            type="button"
            onClick={exportManifest}
            disabled={entries.length === 0}
            className="med-btn med-btn-3 med-focusable disabled:opacity-50 disabled:cursor-not-allowed"
          >
            <FileDown className="w-4 h-4" /> 导出审计清单
          </button>
        </div>

        <div className="med-card overflow-hidden">
          <table className="w-full text-body">
            {/* 表头按规范的 caption 一档:12 · 600 · 0.05em · 纸底 */}
            <thead className="bg-paper text-caption text-ink-3 uppercase">
              <tr>
                <th className="text-left px-4 py-2.5 border-b border-line">时间</th>
                <th className="text-left px-4 py-2.5 border-b border-line">动作</th>
                <th className="text-left px-4 py-2.5 border-b border-line">文件/详情</th>
                <th className="text-left px-4 py-2.5 border-b border-line">哈希</th>
                <th className="text-left px-4 py-2.5 border-b border-line">设备</th>
              </tr>
            </thead>
            <tbody>
              {entries.map((e) => (
                // 时间戳 / 哈希 / 设备号成列,必须等宽才对得齐
                <tr key={e.seq} className="border-t border-line-2">
                  <td className="px-4 py-2.5 text-secondary font-mono tabular-nums text-ink-2 whitespace-nowrap">
                    {fmtTs(e.timestamp)}
                  </td>
                  <td className="px-4 py-2.5">
                    <span className={`med-pill ${ACTION_BADGE[e.action] ?? "bg-line-2 text-ink-2"}`}>
                      {e.action}
                    </span>
                  </td>
                  <td className="px-4 py-2.5 text-ink max-w-xs truncate" title={e.detail}>
                    {e.detail}
                  </td>
                  <td className="px-4 py-2.5">
                    {e.sha256 ? (
                      <button
                        type="button"
                        onClick={() => copyHash(e.seq, e.sha256 as string)}
                        title={e.sha256}
                        className="med-focusable flex items-center gap-1.5 rounded-ctl text-secondary font-mono tabular-nums text-ink-2 hover:text-seal cursor-pointer"
                      >
                        {copiedSeq === e.seq ? (
                          <Check className="w-3.5 h-3.5" />
                        ) : (
                          <Copy className="w-3.5 h-3.5" />
                        )}
                        {shortHash(e.sha256)}
                      </button>
                    ) : (
                      <span className="text-secondary text-ink-3">—</span>
                    )}
                  </td>
                  <td className="px-4 py-2.5 text-secondary font-mono tabular-nums text-ink-3 whitespace-nowrap">
                    {e.device_id.slice(0, 8)}
                  </td>
                </tr>
              ))}
              {entries.length === 0 && !error && (
                <tr>
                  <td colSpan={5} className="px-4 py-8 text-center text-body text-ink-3">
                    暂无记录 —— 导入、导出或分享后,这里会逐条记下来。
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
