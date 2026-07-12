// 化验行结构化解析(纯函数,便于单测)。与桌面端 apps/desktop/src/labTable.ts 是
// 同一处修复的镜像:两端各自独立打包,没有共享的 TS 包,故各自维护一份。
//
// 背景:PDF 文本提取器(pdf-extract)会把所有空白折叠成单个空格,原本靠"两个以上
// 空格"分列的化验行(旧实现 split(/\s{2,}/))因此退化成一整行散文本,无法再按列
// 切分。这里改用"结构"而非"空白宽度"来切列:
//   值(VALUE) = 第一个独立的数字 token(如 6.05 / 7.1 / 95)
//   单位(UNIT) = 紧跟在值后面的 token,前提是它不像参考范围的起始(否则视为无单位)
//   项目名(NAME) = 值之前的所有 token
//   参考范围/提示(RANGE) = 单位之后的所有 token(如 "< 5.20 ↑" / "3.9 - 6.1 ↑")

export interface LabRow {
  name: string;
  value: string;
  unit: string;
  range: string;
  flag: "hi" | "lo" | "";
}

const NUM_RE = /^-?\d+(\.\d+)?$/;
const RANGE_START_RE = /^[<>≤≥]/;

function labFlag(range: string): LabRow["flag"] {
  if (/↑|偏高|升高/.test(range)) return "hi";
  if (/↓|偏低|降低/.test(range)) return "lo";
  return "";
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

// 化验表表头行(如"项目缩写 项目名称 结果 单位 参考范围 提示")—— 识别出来后跳过,
// 不当作普通段落展示(表头本身不含数字,parseLabRow 对其恒返回 null)。
export function isLabHeaderLine(line: string): boolean {
  const keys = ["项目", "结果", "单位", "参考", "提示", "名称", "缩写"];
  const hits = keys.filter((k) => line.includes(k)).length;
  return hits >= 2 && !/\d/.test(line);
}
