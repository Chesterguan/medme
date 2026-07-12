// 化验行结构化解析的单测。喂入 pdf-extract 把所有空白折叠成单空格后的真实行
// (原始 PDF 里各列靠多空格对齐,提取后退化成单空格分隔的散文本),验证仍能按
// 结构切出 项目名/结果/单位/参考范围+提示。
import { test } from "node:test";
import assert from "node:assert/strict";
import { isLabHeaderLine, parseLabRow, tryParseLabRun } from "../src/labTable.ts";

// 血脂血糖化验单示例(单空格,来自 pdf-extract 的真实输出形态)。
const HEADER = "项目缩写 项目名称 结果 单位 参考范围 提示";
const ROWS = [
  "TC 总胆固醇 Cholesterol 6.05 mmol/L < 5.20 ↑",
  "TG 甘油三酯 Triglyceride 2.35 mmol/L < 1.70 ↑",
  "HDL-C 高密度脂蛋白胆固醇 0.98 mmol/L > 1.04 ↓",
  "GLU 空腹血糖 Glucose 7.1 mmol/L 3.9 - 6.1 ↑",
  "HbA1c 糖化血红蛋白 6.9 % 4.0 - 6.0 ↑",
  "Cr 肌酐 Creatinine 95 umol/L 57 - 97 正常",
  "BUN 尿素氮 6.1 mmol/L 3.1 - 8.0 正常",
];

test("isLabHeaderLine 识别化验表表头,且表头本身不是数据行", () => {
  assert.equal(isLabHeaderLine(HEADER), true);
  assert.equal(parseLabRow(HEADER), null);
});

test("parseLabRow 把单空格行按结构切成 名称/值/单位/范围+提示", () => {
  assert.deepEqual(parseLabRow(ROWS[0]), {
    name: "TC 总胆固醇 Cholesterol",
    value: "6.05",
    unit: "mmol/L",
    range: "< 5.20 ↑",
    flag: "high",
  });
  assert.deepEqual(parseLabRow(ROWS[1]), {
    name: "TG 甘油三酯 Triglyceride",
    value: "2.35",
    unit: "mmol/L",
    range: "< 1.70 ↑",
    flag: "high",
  });
  assert.deepEqual(parseLabRow(ROWS[2]), {
    name: "HDL-C 高密度脂蛋白胆固醇",
    value: "0.98",
    unit: "mmol/L",
    range: "> 1.04 ↓",
    flag: "low",
  });
  assert.deepEqual(parseLabRow(ROWS[3]), {
    name: "GLU 空腹血糖 Glucose",
    value: "7.1",
    unit: "mmol/L",
    range: "3.9 - 6.1 ↑",
    flag: "high",
  });
  assert.deepEqual(parseLabRow(ROWS[4]), {
    name: "HbA1c 糖化血红蛋白",
    value: "6.9",
    unit: "%",
    range: "4.0 - 6.0 ↑",
    flag: "high",
  });
  assert.deepEqual(parseLabRow(ROWS[5]), {
    name: "Cr 肌酐 Creatinine",
    value: "95",
    unit: "umol/L",
    range: "57 - 97 正常",
    flag: "normal",
  });
  assert.deepEqual(parseLabRow(ROWS[6]), {
    name: "BUN 尿素氮",
    value: "6.1",
    unit: "mmol/L",
    range: "3.1 - 8.0 正常",
    flag: "normal",
  });
});

test("parseLabRow 对没有单位的行也能优雅处理(值后直接是参考范围)", () => {
  const row = parseLabRow("WBC 白细胞计数 5.2 3.5 - 9.5 正常");
  assert.deepEqual(row, {
    name: "WBC 白细胞计数",
    value: "5.2",
    unit: "",
    range: "3.5 - 9.5 正常",
    flag: "normal",
  });
});

test("parseLabRow 对普通段落(无独立数值,或数值打头)返回 null", () => {
  assert.equal(parseLabRow("患者近期体检未见明显异常。"), null);
  assert.equal(parseLabRow("6.05 单独一个数字打头,前面没有项目名"), null);
  assert.equal(parseLabRow("孤零零一个数字 6.05"), null); // 值后没有任何内容
});

test("tryParseLabRun 消费表头 + 连续 ≥3 行化验数据,整段判定为化验表", () => {
  const lines = [HEADER, ...ROWS, "", "备注:空腹采血。"];
  const run = tryParseLabRun(lines, 0);
  assert.ok(run);
  assert.equal(run.rows.length, ROWS.length);
  assert.equal(run.rows[0].name, "TC 总胆固醇 Cholesterol");
  assert.equal(lines[run.next].trim(), "备注:空腹采血。"); // 停在化验表之后的下一段落
});

// 实测发现:pdf_extract 对本 app 打包的真实化验单 PDF(见
// apps/desktop/src-tauri/demo-data/corpus/*血脂*.pdf)提取出的文本,每一"行"之间
// 都夹了一个空行(不是只把行内多空格折叠成单空格,连行与行之间也多了空行)。
// 若不容忍这一个空行,连续行判定会在第 1 行后就被打断,永远凑不够 3 行 —— 复现
// 这个真实形态,确保修复对线上会遇到的情况真正生效,而不仅仅是对着人工拼的无空行样例。
test("tryParseLabRun 容忍化验行之间夹杂的单个空行(真实 pdf-extract 输出形态)", () => {
  const lines = [
    HEADER,
    "",
    ROWS[0],
    "",
    ROWS[1],
    "",
    ROWS[2],
    "",
    ROWS[3],
    "",
    "提示:血脂四项异常,建议内分泌科随诊。",
    "",
  ];
  const run = tryParseLabRun(lines, 0);
  assert.ok(run);
  assert.equal(run.rows.length, 4);
  assert.equal(run.rows[0].name, "TC 总胆固醇 Cholesterol");
  assert.equal(run.rows[3].name, "GLU 空腹血糖 Glucose");
  assert.equal(lines[run.next].trim(), "提示:血脂四项异常,建议内分泌科随诊。");
});

test("tryParseLabRun 连续 ≥2 行空行判定为真正的段落分隔,不再当作化验行间隔", () => {
  const lines = [HEADER, "", ROWS[0], "", "", ROWS[1], ROWS[2]];
  // TC 后面是两个空行 → 表格在此截断,只拿到 1 行,不足 3 行 → 判定失败
  assert.equal(tryParseLabRun(lines, 0), null);
});

test("tryParseLabRun 不足 3 行连续化验行时判定失败,交回通用解析", () => {
  const lines = [HEADER, ROWS[0], ROWS[1], "以下省略,仅两行数据。"];
  assert.equal(tryParseLabRun(lines, 0), null);
});

test("tryParseLabRun 没有表头也能从数据行直接起判(单元测试里另有真实报告场景)", () => {
  const run = tryParseLabRun(ROWS, 0);
  assert.ok(run);
  assert.equal(run.rows.length, ROWS.length);
  assert.equal(run.next, ROWS.length);
});
