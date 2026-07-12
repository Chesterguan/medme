// 化验行结构化解析的单测(移动端镜像,见 apps/desktop/test/labTable.test.ts)。
// 喂入 pdf-extract 把所有空白折叠成单空格后的真实行,验证仍能按结构切出
// 项目名/结果/单位/参考范围+提示。
import { test } from "node:test";
import assert from "node:assert/strict";
import { isLabHeaderLine, parseLabRow } from "../src/labTable.ts";

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
    flag: "hi",
  });
  assert.deepEqual(parseLabRow(ROWS[2]), {
    name: "HDL-C 高密度脂蛋白胆固醇",
    value: "0.98",
    unit: "mmol/L",
    range: "> 1.04 ↓",
    flag: "lo",
  });
  assert.deepEqual(parseLabRow(ROWS[3]), {
    name: "GLU 空腹血糖 Glucose",
    value: "7.1",
    unit: "mmol/L",
    range: "3.9 - 6.1 ↑",
    flag: "hi",
  });
  assert.deepEqual(parseLabRow(ROWS[5]), {
    name: "Cr 肌酐 Creatinine",
    value: "95",
    unit: "umol/L",
    range: "57 - 97 正常",
    flag: "",
  });
});

test("parseLabRow 对没有单位的行也能优雅处理(值后直接是参考范围)", () => {
  const row = parseLabRow("WBC 白细胞计数 5.2 3.5 - 9.5 正常");
  assert.deepEqual(row, {
    name: "WBC 白细胞计数",
    value: "5.2",
    unit: "",
    range: "3.5 - 9.5 正常",
    flag: "",
  });
});

test("parseLabRow 对普通段落(无独立数值,或数值打头)返回 null", () => {
  assert.equal(parseLabRow("患者近期体检未见明显异常。"), null);
  assert.equal(parseLabRow("6.05 单独一个数字打头,前面没有项目名"), null);
  assert.equal(parseLabRow("孤零零一个数字 6.05"), null);
});
