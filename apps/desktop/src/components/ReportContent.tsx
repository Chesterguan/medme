// 内容感知渲染(维度B):按文档类型富渲染。
//  - 化验 → 表格(指标/值/参考范围/↑↓)
//  - 处方 → 用药清单卡片
//  - 病理/影像/出院/病历/手术 → 分节 + 行内标签加粗
// 解析不到结构就退回干净文本 —— 永不比原文更糟(见 memory: content-aware-rendering)。
//
// 视觉:设计系统 v1(见 ../tokens.css)。化验表的状态编色是**跨端硬性对齐**的一条
// 规矩,移植自 mobile_flutter/lib/widgets/report_content.dart,逐条照抄:
//   - 颜色只编码严重度(偏高/偏低),不编码文档类型。
//   - 正常与无标记不上色,继承正文墨色 —— 一份血常规 22 项通常只有 1–2 项异常,
//     给正常配色会把异常淹没。
//   - 状态**同时**编码在左侧色条与文字 pill 上:色盲用户靠 pill 读「偏低/偏高」,
//     正常视力扫视靠色条,少一个就有一类用户读不到结论。
//   - 无绿色(规范明令排除,见 ImportView.tsx 关于加密分享卡改版的说明)。

import { tryParseLabRun, type LabRow } from "../labTable";

type Flag = LabRow["flag"]; // "high" | "low" | "normal" | null —— 与手机端 LabFlag 同构

type Block =
  | { kind: "table"; header: string[] | null; rows: string[][] }
  | { kind: "labtable"; rows: LabRow[] }
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

function rowStatus(cells: string[]): Flag {
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
    // 化验单单空格塌陷场景:先按结构尝试识别连续的化验行(见 labTable.ts),
    // 命中则优先于下面基于"多空格分列"的通用表格解析。
    const labRun = tryParseLabRun(lines, i);
    if (labRun) {
      blocks.push({ kind: "labtable", rows: labRun.rows });
      i = labRun.next;
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

// 化验状态 → 前景色。正常/无标记**不上色**,继承正文墨色(见文件头注释)。
// 对比度(WCAG AA 正文 4.5:1):#b45309(high)/#fff = 5.02:1,#1d4ed8(low)/#fff = 6.70:1。
const flagTextClass = (f: Flag) =>
  f === "high" ? "text-high" : f === "low" ? "text-low" : "text-ink";

// 化验状态 → 左侧 3px 色条(border-left)。正常/无标记是透明占位,不是不画 ——
// 占位恒定,异常行才有颜色,整列文字起点不会因为有没有色条而左右跳。
const flagStripeClass = (f: Flag) =>
  f === "high" ? "border-l-high" : f === "low" ? "border-l-low" : "border-l-transparent";

// 化验状态 → 文字 pill。正常/无标记不给 pill —— 状态同时编码在色条和 pill 上,
// 色盲用户靠这个读「偏低/偏高」。对比度:high-wash/high ≈ 4.50:1,low-wash/low = 5.77:1。
function FlagPill({ flag }: { flag: Flag }) {
  if (flag === "high") return <span className="med-pill bg-high-wash text-high">偏高</span>;
  if (flag === "low") return <span className="med-pill bg-low-wash text-low">偏低</span>;
  return null;
}

// 行内"标签:内容" → 标签加粗(主诉:/病理诊断:/诊断意见:…)
const LABEL_RE = /^([一-龥A-Za-z]{2,10})([:：])(.*)$/;
function Para({ text }: { text: string }) {
  const t = text.trimEnd();
  const m = t.match(LABEL_RE);
  if (m && m[3].trim().length > 0) {
    return (
      <div className="whitespace-pre-wrap">
        <span className="font-semibold text-ink">
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

// 化验表:一行一项,状态编码在左侧 3px 色条 + 文字 pill 上(移植自 report_content.dart
// 的 _LabTableView/_LabRowView)。相对旧版(四列 <table> + 斑马纹 + 整行文字统一上色)
// 的结构性改动:
//  - 斑马纹去掉,行间改用 line-2 细线 —— 规范「层次靠边框不靠阴影」,斑马纹在 22
//    行的血常规上是纯噪声,还会和状态底色打架。
//  - 不再是四列 <table>:项目名单占一栏,结果/单位/参考区间收进右栏两行,数值右对齐
//    + 等宽,一列数字自然对齐,也不会把中文项目名挤窄。
function LabTable({ rows }: { rows: LabRow[] }) {
  return (
    <div className="rounded-block border border-line overflow-hidden bg-surface">
      <div className="flex bg-paper px-3 py-2">
        <span className="flex-[3] text-caption text-ink-3">项目</span>
        <span className="flex-[2] text-caption text-ink-3 text-right">结果 / 参考区间</span>
      </div>
      {rows.map((r, i) => (
        <div
          key={i}
          className={`flex items-start gap-3 pl-[9px] pr-3 py-[9px] border-l-[3px] ${flagStripeClass(
            r.flag,
          )} ${i < rows.length - 1 ? "border-b border-line-2" : ""}`}
        >
          <div className="flex-[3] flex flex-wrap items-center gap-x-1.5 gap-y-1 min-w-0">
            <span className="text-body text-ink">{r.name}</span>
            <FlagPill flag={r.flag} />
          </div>
          <div className="flex-[2] text-right">
            <span className={`text-body font-semibold font-mono tabular-nums ${flagTextClass(r.flag)}`}>
              {r.value}
            </span>
            {r.unit && <span className="text-secondary font-mono text-ink-3"> {r.unit}</span>}
            {r.range && (
              <div className="text-caption font-normal font-mono tabular-nums text-ink-3">
                {r.range}
              </div>
            )}
          </div>
        </div>
      ))}
    </div>
  );
}

function GenericBlocks({ blocks }: { blocks: Block[] }) {
  return (
    <>
      {blocks.map((b, i) => {
        if (b.kind === "labtable") {
          return <LabTable key={i} rows={b.rows} />;
        }
        if (b.kind === "table") {
          const cols = Math.max(b.header?.length ?? 0, ...b.rows.map((r) => r.length));
          return (
            <div key={i} className="overflow-x-auto rounded-block border border-line bg-surface">
              <table className="w-full text-body border-collapse">
                {b.header && (
                  <thead>
                    <tr className="bg-paper text-caption text-ink-3 uppercase">
                      {b.header.map((h, j) => (
                        <th
                          key={j}
                          className="text-left font-medium px-3 py-2 border-b border-line whitespace-nowrap"
                        >
                          {h}
                        </th>
                      ))}
                    </tr>
                  </thead>
                )}
                <tbody>
                  {b.rows.map((r, ri) => (
                    <tr key={ri} className="border-t border-line-2">
                      {Array.from({ length: cols }).map((_, ci) => (
                        <td
                          key={ci}
                          className={`px-3 py-1.5 font-mono tabular-nums whitespace-nowrap ${flagTextClass(
                            rowStatus(r),
                          )}`}
                        >
                          {r[ci] ?? ""}
                        </td>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          );
        }
        if (b.kind === "section") {
          // 分节标题(【…】/「主诉:」这类)走 subtitle 一档(17·600),比正文明确高
          // 一档 —— 只靠字重区分,在放大后的字阶里几乎分不开(与手机端一致)。
          return (
            <div key={i} className="text-subtitle font-semibold text-ink pt-1">
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
  if (!text.trim()) return <div className="text-ink-3 text-body">无文本内容。</div>;

  // 处方 → 用药清单
  if (docType === "prescription") {
    const p = parseMeds(text);
    if (p) {
      return (
        <div className="space-y-4 text-body text-ink">
          {p.intro.length > 0 && (
            <div className="space-y-1">
              {p.intro.map((t, i) => (
                <Para key={i} text={t} />
              ))}
            </div>
          )}
          <div className="text-caption font-mono text-ink-3 uppercase">用药</div>
          <div className="space-y-2">
            {p.meds.map((m, i) => (
              // 改版前是 emerald 绿卡 —— 规范色板里没有绿(绿=正常/安全正是规范刻意
              // 不做的暗示,见 ImportView.tsx)。改成中性分块(paper 底 + line-2 边),
              // 序号用主色 seal:清单要好数,不要好看。
              <div key={i} className="flex gap-3 bg-paper border border-line-2 rounded-block p-3">
                <div className="w-7 h-7 rounded-ctl bg-seal-wash text-seal-ink flex items-center justify-center shrink-0 text-caption font-bold tabular-nums">
                  {i + 1}
                </div>
                <div className="min-w-0">
                  <div className="font-semibold text-ink">{m.name}</div>
                  {m.usage.map((u, j) => (
                    <div key={j} className="text-secondary text-ink-2 leading-relaxed">
                      {u}
                    </div>
                  ))}
                </div>
              </div>
            ))}
          </div>
          {p.footer.length > 0 && (
            <div className="space-y-1 text-secondary text-ink-3">
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
    <div className="space-y-4 text-body text-ink">
      <GenericBlocks blocks={parse(text)} />
    </div>
  );
}
