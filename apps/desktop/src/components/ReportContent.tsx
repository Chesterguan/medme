// 内容感知渲染(维度B):按文档类型富渲染。
//  - 化验 → 表格(指标/值/参考范围/↑↓)
//  - 处方 → 用药清单卡片
//  - 病理/影像/出院/病历/手术 → 分节 + 行内标签加粗
// 解析不到结构就退回干净文本 —— 永不比原文更糟(见 memory: content-aware-rendering)。

type Block =
  | { kind: "table"; header: string[] | null; rows: string[][] }
  | { kind: "section"; text: string }
  | { kind: "para"; text: string };

function splitCells(line: string): string[] {
  return line
    .trim()
    .split(/\s{2,}|\t/)
    .filter((c) => c.length > 0);
}

function isTableHeader(line: string): boolean {
  const keys = ["项目", "结果", "单位", "参考", "提示", "名称", "缩写"];
  return keys.filter((k) => line.includes(k)).length >= 2 && splitCells(line).length >= 3;
}

function isDataRow(line: string): boolean {
  return splitCells(line).length >= 3 && /\d/.test(line);
}

function rowStatus(cells: string[]): "high" | "low" | "normal" | null {
  const j = cells.join(" ");
  if (cells.includes("↑") || /↑|偏高|升高/.test(j)) return "high";
  if (cells.includes("↓") || /↓|偏低|降低|减低/.test(j)) return "low";
  if (/正常/.test(j)) return "normal";
  return null;
}

function parse(text: string): Block[] {
  const lines = text.split(/\r?\n/);
  const blocks: Block[] = [];
  let i = 0;
  while (i < lines.length) {
    const trimmed = lines[i].trim();
    if (!trimmed) {
      i++;
      continue;
    }
    if (isTableHeader(trimmed) || isDataRow(trimmed)) {
      const start = i;
      const header = isTableHeader(trimmed) ? splitCells(trimmed) : null;
      if (header) i++;
      const rows: string[][] = [];
      while (i < lines.length && lines[i].trim() && isDataRow(lines[i])) {
        rows.push(splitCells(lines[i]));
        i++;
      }
      if (rows.length >= 2) {
        blocks.push({ kind: "table", header, rows });
        continue;
      }
      i = start;
    }
    if (/^[【[].+[】\]]$/.test(trimmed) || (trimmed.length <= 14 && /[:：]$/.test(trimmed))) {
      blocks.push({ kind: "section", text: trimmed });
    } else {
      blocks.push({ kind: "para", text: lines[i] });
    }
    i++;
  }
  return blocks;
}

const statusText = (s: string | null) =>
  s === "high" ? "text-amber-700" : s === "low" ? "text-blue-700" : "text-slate-700";

// 行内"标签:内容" → 标签加粗(主诉:/病理诊断:/诊断意见:…)
const LABEL_RE = /^([一-龥A-Za-z]{2,10})([:：])(.*)$/;
function Para({ text }: { text: string }) {
  const t = text.trimEnd();
  const m = t.match(LABEL_RE);
  if (m && m[3].trim().length > 0) {
    return (
      <div className="whitespace-pre-wrap">
        <span className="font-semibold text-slate-900">
          {m[1]}
          {m[2]}
        </span>
        {m[3]}
      </div>
    );
  }
  return <div className="whitespace-pre-wrap">{text}</div>;
}

// ── 处方:用药清单 ──
interface Med {
  name: string;
  usage: string[];
}
function parseMeds(text: string): { intro: string[]; meds: Med[]; footer: string[] } | null {
  const lines = text.split(/\r?\n/);
  const meds: Med[] = [];
  const intro: string[] = [];
  const footer: string[] = [];
  let cur: Med | null = null;
  let started = false;
  let ended = false;
  for (const raw of lines) {
    const line = raw.trim();
    const numbered = line.match(/^(\d+)\s*[.、)]\s*(.+)/);
    if (numbered) {
      started = true;
      ended = false;
      if (cur) meds.push(cur);
      cur = { name: numbered[2].trim(), usage: [] };
      continue;
    }
    if (/^(医师|药师|审核|备注|Rp\.?|处方)/.test(line)) {
      if (cur) {
        meds.push(cur);
        cur = null;
      }
      if (started) ended = true;
      if (line && !/^Rp\.?$/.test(line)) {
        if (started) footer.push(line);
        else intro.push(line);
      }
      continue;
    }
    if (cur && line) {
      cur.usage.push(line);
      continue;
    }
    if (line) {
      if (!started) intro.push(line);
      else if (ended) footer.push(line);
    }
  }
  if (cur) meds.push(cur);
  return meds.length ? { intro, meds, footer } : null;
}

function GenericBlocks({ blocks }: { blocks: Block[] }) {
  return (
    <>
      {blocks.map((b, i) => {
        if (b.kind === "table") {
          const cols = Math.max(b.header?.length ?? 0, ...b.rows.map((r) => r.length));
          return (
            <div key={i} className="overflow-x-auto rounded-xl border border-slate-200">
              <table className="w-full text-sm border-collapse">
                {b.header && (
                  <thead>
                    <tr className="bg-slate-50 text-slate-500 text-xs">
                      {b.header.map((h, j) => (
                        <th
                          key={j}
                          className="text-left font-medium px-3 py-2 border-b border-slate-200 whitespace-nowrap"
                        >
                          {h}
                        </th>
                      ))}
                    </tr>
                  </thead>
                )}
                <tbody>
                  {b.rows.map((r, ri) => {
                    const st = rowStatus(r);
                    return (
                      <tr key={ri} className={`${ri % 2 ? "bg-slate-50/40" : ""} ${statusText(st)}`}>
                        {Array.from({ length: cols }).map((_, ci) => (
                          <td
                            key={ci}
                            className="px-3 py-1.5 font-mono border-b border-slate-100 whitespace-nowrap"
                          >
                            {r[ci] ?? ""}
                          </td>
                        ))}
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          );
        }
        if (b.kind === "section") {
          return (
            <div key={i} className="font-semibold text-slate-900 pt-1">
              {b.text}
            </div>
          );
        }
        return <Para key={i} text={b.text} />;
      })}
    </>
  );
}

export default function ReportContent({ text, docType }: { text: string; docType?: string }) {
  if (!text.trim()) return <div className="text-slate-400 text-sm">无文本内容。</div>;

  // 处方 → 用药清单
  if (docType === "prescription") {
    const p = parseMeds(text);
    if (p) {
      return (
        <div className="space-y-4 text-[15px] leading-relaxed text-slate-700">
          {p.intro.length > 0 && (
            <div className="space-y-1">
              {p.intro.map((t, i) => (
                <Para key={i} text={t} />
              ))}
            </div>
          )}
          <div className="text-[11px] font-mono text-slate-400 uppercase tracking-widest">用药</div>
          <div className="space-y-2">
            {p.meds.map((m, i) => (
              <div
                key={i}
                className="flex gap-3 bg-emerald-50/40 border border-emerald-100 rounded-xl p-3"
              >
                <div className="w-7 h-7 rounded-lg bg-emerald-100 text-emerald-700 flex items-center justify-center shrink-0 text-sm font-bold">
                  {i + 1}
                </div>
                <div className="min-w-0">
                  <div className="font-medium text-slate-800">{m.name}</div>
                  {m.usage.map((u, j) => (
                    <div key={j} className="text-sm text-slate-500 leading-relaxed">
                      {u}
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </div>
          {p.footer.length > 0 && (
            <div className="space-y-1 text-sm text-slate-500">
              {p.footer.map((t, i) => (
                <Para key={i} text={t} />
              ))}
            </div>
          )}
        </div>
      );
    }
  }

  // 其余类型(化验表格 / 病理·影像·出院·病历·手术 分节+行内标签 / 通用)
  return (
    <div className="space-y-4 text-[15px] leading-relaxed text-slate-700">
      <GenericBlocks blocks={parse(text)} />
    </div>
  );
}
