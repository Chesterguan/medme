// 设计系统 v1 令牌的看门测试(桌面端)。
//
// 和 mobile_flutter/test/design_tokens_test.dart 是同一份规范的两侧断言:规范
// (DESIGN-SYSTEM-v1.html) 里的每个色值在这里逐一钉住,谁随手改一个 CSS 变量,红
// 的是这里 —— 而不是三个月后有人发现手机和桌面的「偏高」不是同一个橙。
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const css = readFileSync(
  fileURLToPath(new URL("../src/tokens.css", import.meta.url)),
  "utf8",
);
const appCss = readFileSync(
  fileURLToPath(new URL("../src/App.css", import.meta.url)),
  "utf8",
);

/** 取出某个选择器块里的全部自定义属性。 */
function varsIn(selector: string): Record<string, string> {
  const at = css.indexOf(selector);
  assert.notEqual(at, -1, `tokens.css 里找不到选择器 ${selector}`);
  const open = css.indexOf("{", at);
  // 顶层 :root 与 @media 内的 :root 都是单层花括号块,逐字符配对即可。
  let depth = 0;
  let end = open;
  for (let i = open; i < css.length; i++) {
    if (css[i] === "{") depth++;
    else if (css[i] === "}" && --depth === 0) {
      end = i;
      break;
    }
  }
  const body = css.slice(open + 1, end);
  const out: Record<string, string> = {};
  for (const m of body.matchAll(/(--[a-z0-9-]+)\s*:\s*([^;]+);/g)) {
    out[m[1]] = m[2].trim();
  }
  return out;
}

// 逐字抄自 DESIGN-SYSTEM-v1.html 的 `:root`。
const SPEC_LIGHT: Record<string, string> = {
  "--ink": "#101a23",
  "--ink-2": "#3a4a57",
  "--ink-3": "#6b7c89",
  "--paper": "#f6f8fa",
  "--surface": "#ffffff",
  "--line": "#e3e9ee",
  "--line-2": "#eef2f5",
  "--seal": "#1789c1",
  "--seal-ink": "#0e6285",
  "--seal-wash": "#eaf5fa",
  "--low": "#1d4ed8",
  "--low-wash": "#e8eefc",
  "--high": "#b45309",
  "--high-wash": "#fbf1e4",
  "--critical": "#be123c",
  "--critical-wash": "#fceaef",
};

// 逐字抄自规范的 `prefers-color-scheme:dark` / `[data-theme="dark"]` 块。
const SPEC_DARK: Record<string, string> = {
  "--ink": "#e8eef3",
  "--ink-2": "#a6b6c2",
  "--ink-3": "#7c8d9a",
  "--paper": "#0d141a",
  "--surface": "#151f27",
  "--line": "#25333d",
  "--line-2": "#1d2830",
  "--seal": "#4fb3df",
  "--seal-ink": "#8fd3f0",
  "--seal-wash": "#13303d",
  "--low": "#7ba3f5",
  "--low-wash": "#17233d",
  "--high": "#e0a45c",
  "--high-wash": "#33260f",
  "--critical": "#f2789a",
  "--critical-wash": "#3a1521",
};

test("浅色令牌与 DESIGN-SYSTEM-v1 逐一一致", () => {
  const actual = varsIn(":root {");
  for (const [name, hex] of Object.entries(SPEC_LIGHT)) {
    assert.equal(actual[name], hex, `${name} 与规范不符`);
  }
});

test("深色令牌在系统偏好与显式 data-theme 两处都与规范一致", () => {
  for (const selector of ["@media (prefers-color-scheme: dark)", ':root[data-theme="dark"]']) {
    const actual = varsIn(selector);
    for (const [name, hex] of Object.entries(SPEC_DARK)) {
      assert.equal(actual[name], hex, `${selector} 里的 ${name} 与规范不符`);
    }
  }
});

test('显式 data-theme="light" 与默认浅色一致 —— 手动切回浅色不能是另一套颜色', () => {
  const explicit = varsIn(':root[data-theme="light"]');
  for (const [name, hex] of Object.entries(SPEC_LIGHT)) {
    assert.equal(explicit[name], hex, `${name} 与默认浅色不符`);
  }
});

test("圆角严格递减,间距为 8/12/16/20/24/32", () => {
  const v = varsIn(":root {");
  assert.equal(v["--r-card"], "20px");
  assert.equal(v["--r-block"], "14px");
  assert.equal(v["--r-ctl"], "10px");
  const radii = [v["--r-card"], v["--r-block"], v["--r-ctl"]].map(parseFloat);
  for (let i = 1; i < radii.length; i++) {
    assert.ok(radii[i] < radii[i - 1], "圆角必须递减,嵌套时不能同级");
  }
  assert.deepEqual(
    ["--s1", "--s2", "--s3", "--s4", "--s5", "--s6"].map((k) => v[k]),
    ["8px", "12px", "16px", "20px", "24px", "32px"],
  );
});

test("阴影只有一档", () => {
  assert.equal(varsIn(":root {")["--shadow"], "0 1px 2px rgba(16, 26, 35, 0.05)");
  assert.equal(
    varsIn('@media (prefers-color-scheme: dark)')["--shadow"],
    "0 1px 2px rgba(0, 0, 0, 0.3)",
  );
  // 规范里阴影只有这一档:整份 tokens.css 不许出现第二种 box-shadow 值。
  const shadows = new Set(
    [...css.matchAll(/--shadow\s*:\s*([^;]+);/g)].map((m) => m[1].trim()),
  );
  assert.equal(shadows.size, 2, "阴影档数超过「浅色一档 + 深色一档」");
});

test("正常态刻意没有令牌 —— 正常值不上色,继承正文", () => {
  const v = varsIn(":root {");
  assert.ok(!("--normal" in v) && !("--normal-wash" in v));
});

test("令牌被 App.css 引入,且没有覆盖既有的 blue-* 品牌重映射", () => {
  assert.match(appCss, /@import\s+"\.\/tokens\.css";/);
  // 既有的 Tailwind @theme 品牌色照旧存在。
  assert.match(appCss, /--color-blue-600:\s*#1789c1;/);
  // 令牌用的是 Tailwind 主题命名空间之外的裸名,不会互相覆盖。
  for (const name of Object.keys(SPEC_LIGHT)) {
    assert.ok(
      !/^--(color|text|font|radius|shadow|spacing|breakpoint|container|tracking|leading|ease|animate|blur|aspect)-/.test(
        name,
      ),
      `${name} 落进了 Tailwind 的主题命名空间,会和 @theme 打架`,
    );
  }
});
