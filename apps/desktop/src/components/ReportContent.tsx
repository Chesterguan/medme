// 内容感知渲染:把化验单等表格化文本渲染成真表格,章节加粗,其余段落干净排版。
// 检测不到表格时退回纯文本 —— 永不比原始文本更糟(见 memory: content-aware-rendering)。

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

    // 表格区:可选表头 + 连续 ≥2 数据行
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
      i = start; // 不足以成表 → 回退
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

export default function ReportContent({ text }: { text: string }) {
  if (!text.trim()) return <div className="text-slate-400 text-sm">无文本内容。</div>;
  const blocks = parse(text);

  return (
    <div className="space-y-4 text-[15px] leading-relaxed text-slate-700">
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
        return (
          <div key={i} className="whitespace-pre-wrap">
            {b.text}
          </div>
        );
      })}
    </div>
  );
}
