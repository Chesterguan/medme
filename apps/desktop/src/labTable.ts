// 化验单结构化解析(纯函数,便于单测)。
//
// 背景:PDF 文本提取器(pdf-extract)会把所有空白折叠成单个空格,原本靠"两个以上
// 空格/Tab"分列的化验行(见 ReportContent.tsx 的 splitCells)因此退化成一整行散文本,
// 无法再按列切分。这里改用"结构"而非"空白宽度"来切列:
//   值(VALUE) = 第一个独立的数字 token(如 6.05 / 7.1 / 95)
//   单位(UNIT) = 紧跟在值后面的 token,前提是它不像参考范围的起始(否则视为无单位)
//   项目名(NAME) = 值之前的所有 token
//   参考范围/提示(RANGE) = 单位之后的所有 token(如 "< 5.20 ↑" / "3.9 - 6.1 ↑")
// 对形如 "TC 总胆固醇 Cholesterol 6.05 mmol/L < 5.20 ↑" 的单空格行同样适用。

export interface LabRow {
  name: string;
  value: string;
  unit: string;
  range: string;
  flag: "high" | "low" | "normal" | null;
}

const NUM_RE = /^-?\d+(\.\d+)?$/;
const RANGE_START_RE = /^[<>≤≥]/;

function labFlag(range: string): LabRow["flag"] {
  if (/↑|偏高|升高/.test(range)) return "high";
  if (/↓|偏低|降低|减低/.test(range)) return "low";
  if (/正常/.test(range)) return "normal";
  return null;
}

// 把一行拆成结构化的化验行;不像化验行(找不到独立数值,或数值前/后缺内容)则返回 null。
export function parseLabRow(line: string): LabRow | null {
  const tokens = line.trim().split(/\s+/).filter(Boolean);
  if (tokens.length < 2) return null;

  const valueIdx = tokens.findIndex((t) => NUM_RE.test(t));
  if (valueIdx <= 0) return null; // 值前必须有项目名;值本身不能是第一个 token

  const after = tokens.slice(valueIdx + 1);
  if (after.length === 0) return null; // 值后至少要有单位或参考范围,否则不像化验行

  const name = tokens.slice(0, valueIdx).join(" ");
  const value = tokens[valueIdx];

  // 判断值后第一个 token 是参考范围的开头(比较符/数字/连字符),还是单位。
  const nextTok = after[0];
  const looksLikeRangeStart = RANGE_START_RE.test(nextTok) || NUM_RE.test(nextTok) || nextTok === "-";
  const unit = looksLikeRangeStart ? "" : nextTok;
  const rangeTokens = looksLikeRangeStart ? after : after.slice(1);
  const range = rangeTokens.join(" ");

  return { name, value, unit, range, flag: labFlag(range) };
}

// 化验表表头行(如"项目缩写 项目名称 结果 单位 参考范围 提示")—— 只用于识别并消费掉
// 表头,不做数据解析(表头本身不含数字,parseLabRow 对其恒返回 null)。
export function isLabHeaderLine(line: string): boolean {
  const keys = ["项目", "结果", "单位", "参考", "提示", "名称", "缩写"];
  const hits = keys.filter((k) => line.includes(k)).length;
  return hits >= 2 && !/\d/.test(line);
}

// 连续 ≥3 行都能解析成化验行,才判定为化验表(避免把偶尔带数字的普通段落误判)。
const MIN_LAB_ROWS = 3;

export interface LabRun {
  rows: LabRow[];
  /** 下一个未消费的行号(含表头在内)。 */
  next: number;
}

// 只跳过恰好一行空行(实测 pdf-extract 会在提取出的每一"行"之间都插入一个空行,
// 见 examples/demo-dataset 的真实血脂血糖报告——不是段落间距,是逐行现象;
// 连续 ≥2 行空行更像是真正的段落分隔,不再当表格处理)。
function skipSingleBlank(lines: string[], k: number): number {
  return k < lines.length && lines[k].trim() === "" ? k + 1 : k;
}

// 从 lines[i] 开始尝试识别一段连续的化验表:可选的表头行 + ≥3 行连续化验数据行
// (行间允许被 pdf-extract 逐行插入的单个空行打断,见 skipSingleBlank)。
// 识别失败(不足 3 行连续化验行)返回 null,调用方应回退到通用解析。
export function tryParseLabRun(lines: string[], i: number): LabRun | null {
  const trimmed = lines[i].trim();
  const start = isLabHeaderLine(trimmed) ? skipSingleBlank(lines, i + 1) : i;

  const rows: LabRow[] = [];
  let j = start;
  while (j < lines.length) {
    const l = lines[j].trim();
    const row = l ? parseLabRow(l) : null;
    if (!row) break;
    rows.push(row);
    j = skipSingleBlank(lines, j + 1);
  }

  if (rows.length < MIN_LAB_ROWS) return null;
  return { rows, next: j };
}
