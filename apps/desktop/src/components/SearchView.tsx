import { useState } from "react";
import { Search as SearchIcon, FileQuestion } from "lucide-react";
import { api } from "../api";
import type { SearchResult } from "../types";
import { TYPE_ICON, TYPE_BADGE, fmtDate } from "../docmeta";

// FTS body 是 jieba 分词后文本 → 片段里中文之间有空格;渲染时去掉中文间空格。
function deCjkSpace(s: string): string {
  return s.replace(/([一-鿿])\s+(?=[一-鿿])/g, "$1");
}

// 片段中的 [..] 是命中高亮
function renderSnippet(snippet: string) {
  return snippet.split(/(\[[^\]]*\])/g).map((p, i) => {
    if (p.startsWith("[") && p.endsWith("]")) {
      // 命中高亮改用主色 wash:amber 那一族在设计系统里是「偏高」的专属色,
      // 搜索命中借用它会和化验状态撞语义。
      return (
        <mark key={i} className="bg-seal-wash text-seal-ink rounded-sm px-0.5">
          {deCjkSpace(p.slice(1, -1))}
        </mark>
      );
    }
    return <span key={i}>{deCjkSpace(p)}</span>;
  });
}

export default function SearchView({ onSelect }: { onSelect: (id: number) => void }) {
  const [q, setQ] = useState("");
  const [results, setResults] = useState<SearchResult[] | null>(null);
  const [busy, setBusy] = useState(false);

  const run = (query: string) => {
    setQ(query);
    if (!query.trim()) {
      setResults(null);
      return;
    }
    setBusy(true);
    api
      .search(query, 50)
      .then(setResults)
      .catch(() => setResults([]))
      .finally(() => setBusy(false));
  };

  return (
    <div className="flex-1 overflow-y-auto bg-paper p-6 md:p-10">
      <div className="max-w-3xl mx-auto">
        <h1 className="text-display font-bold text-ink mb-6">搜索</h1>
        <div className="relative">
          <SearchIcon className="w-5 h-5 text-ink-3 absolute left-4 top-1/2 -translate-y-1/2" />
          {/* 输入框是控件 → 10px 圆角(改版前是 rounded-2xl 16px,和卡片同级) */}
          <input
            autoFocus
            value={q}
            onChange={(e) => run(e.target.value)}
            placeholder="搜索肌酐、Metoprolol、脂肪肝、CT、胆囊…"
            className="w-full pl-12 pr-4 py-3 rounded-ctl border border-line bg-surface text-body text-ink placeholder:text-ink-3 focus:outline-none focus:border-seal focus:ring-2 focus:ring-seal-wash"
          />
        </div>

        {results !== null && (
          <div className="mt-6 space-y-3">
            {/* 改版前 text-[11px],低于 12px 下限 */}
            <div className="text-caption font-mono tabular-nums text-ink-3 uppercase">
              {busy ? "搜索中…" : `${results.length} 条结果`}
            </div>
            {results.map((r) => {
              const d = r.document;
              const Icon = TYPE_ICON[d.doc_type] ?? FileQuestion;
              return (
                // 搜索结果每一条都点得进原件 → 带骑缝线
                <button
                  key={d.id}
                  onClick={() => onSelect(d.id)}
                  className="med-card med-perf med-focusable w-full text-left px-5 pb-5 pt-6 hover:border-seal transition-colors cursor-pointer group"
                >
                  <div className="flex items-center gap-3">
                    <div
                      className={`w-9 h-9 rounded-ctl flex items-center justify-center shrink-0 ${
                        TYPE_BADGE[d.doc_type] ?? "bg-line-2 text-ink-2"
                      }`}
                    >
                      <Icon className="w-4 h-4" />
                    </div>
                    <span className="text-subtitle font-semibold text-ink group-hover:text-seal-ink truncate flex-1">
                      {d.title ?? "(无标题)"}
                    </span>
                    <span className="text-secondary font-mono tabular-nums text-ink-3 shrink-0">
                      {fmtDate(d.doc_date)}
                    </span>
                  </div>
                  <div className="text-body text-ink-2 mt-2 line-clamp-2">
                    {renderSnippet(r.snippet)}
                  </div>
                </button>
              );
            })}
            {/* 空结果也要给出路,不能只留一句「没有」 */}
            {!busy && results.length === 0 && (
              <div className="med-empty text-body">
                没有匹配「{q}」的记录。换个说法试试 —— 化验项、药名、部位、医院名都能搜。
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
