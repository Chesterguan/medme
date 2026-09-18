// 病程档案渲染的冒烟自检(Task 23)。**不引入任何 JS 测试框架、零依赖**:
//
//     node web/hosted-viewer/renderProfile.smoke.mjs
//
// 仓库里没有 JS 测试框架,也不为这件事引入一个 —— 但 `renderProfile` 有三百来行
// 分支、画的是给医生看的临床内容,只靠 `share.rs` 那条「文件里有没有这个函数名」
// 的钉子测试挡不住任何一个渲染错误。
//
// 手法:从 `index.html` 里**按名字切出那几个纯函数**(`esc` / `sumFlag` / `sparkSVG`
// 与整段病程档案),在没有 DOM 的情况下直接跑。切不出来就当场报错 —— 那说明有人
// 动了这几段的边界,应该来看一眼,而不是让自检静默变成空跑。
//
// 语料用的是引擎自己的 golden(`packages/profile/testdata/golden_profile_view.json`),
// 不另编一份 —— 编的那份必然和引擎真实输出不一致。
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import assert from "node:assert/strict";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(here, "../..");
const html = readFileSync(path.join(repo, "web/hosted-viewer/index.html"), "utf8");
const golden = JSON.parse(
  readFileSync(path.join(repo, "packages/profile/testdata/golden_profile_view.json"), "utf8"),
);

/** 按起止标记切一段源码出来;切不到就报错(边界漂了要人来看)。 */
function slice(from, to) {
  const a = html.indexOf(from);
  assert.notEqual(a, -1, `切不到起点:${from}`);
  const b = html.indexOf(to, a + from.length);
  assert.notEqual(b, -1, `切不到终点:${to}`);
  return html.slice(a, b);
}

const src = [
  slice("function esc(s) {", "// SECURITY: only accept a data: image"),
  slice("const SUM_MN =", "function buildEMRFromSummary"),
  slice("// ── 病程档案(Task 23)", "function render(payload) {"),
  "return { renderProfile };",
].join("\n");
// eslint-disable-next-line no-new-func -- 这就是本文件的全部意义:跑查看器里那段真源码。
const { renderProfile } = new Function(src)();

// ── 1. golden:整份档案画得出来,且每一处都读包给的字 ──────────────────────
const out = renderProfile(golden);
const must = [
  // 标题/免责声明逐字来自包,查看器不改一个字
  golden.display_name,
  golden.package_version,
  golden.disclaimer,
  // 每一块的标题都来自包
  ...golden.sections.map(s => s.title),
  // score_card 三态:满足(✔ + 分值 + 出处 + 证据原文逐字)
  "低补体", "+2 分", "出处 S1", "0.78 g/L · 2026-09-10",
  // 未满足(✘)也要带证据 —— 空着会被读成「没查」
  "dsDNA 升高", "18 IU/mL · 2026-09-10",
  // 现行方案:剂量与它的日期、体重与它的来源和日期
  "泼尼松", "7.5mg qd", "(等效 7.5 mg/日)", "2024-03-15 – 2026-06-15",
  "体重 56 kg(自测) 2026-09-01", "mg/kg 3.5714285714285716(目标 ≤ 5)",
  // 给药途径的 key 不能丢(同一个药 IV/SC 剂量不同)
  "iv: 10 mg/kg", "sc: SLE 每周 200 mg",
  // reminders:依据分档 + 状态,逐字与手机端同
  "指南", "没查到", "该补钙和维生素 D 了",
  // checklist:逐条 ✔/✘/未知,未知必须带原因
  "满足", "未满足", "未知", "还没有人录过医生整体评估(PGA)",
  // series_chart:名字 + 参考区间**两头** + 最新值旁边那个**原始日期**(不是月份)
  "补体C3", "<svg", "参考 0.9–1.8", "2026-09-10",
  // 出处全文查得到
  "Gladman DD",
];
for (const m of must) assert.ok(out.includes(m), `golden 渲染里少了:${m}`);

// 时间轴这一块 golden 里是空的、且包**故意**没给 empty_hint —— 卡片仍要在
// (与手机端一致:查看器既不替它编一句话,也不让整块消失)。
assert.ok(out.includes("病程时间轴"), "空的 timeline 也要出一张带标题的卡");

// 「化验可算部分」这个标签必须在 —— 分数一律带它,不许看起来像一个完整评分。
assert.ok(out.includes("化验可算部分"), "分数旁边少了「化验可算部分」标签");

// ── 2. 认不出的 kind 整块跳过,不抛异常;全认不出则一行都不画 ────────────
assert.equal(
  renderProfile({ display_name: "x", sections: [{ kind: "brand_new_kind", body: {} }], sources: [] }),
  "",
  "认不出的 kind 应整块跳过",
);

// ── 3. 空态:`empty_hint` 原样一行,不拼标题上去 ─────────────────────────
const hinted = renderProfile({
  display_name: "d", sections: [{ kind: "reminders", title: "待补 / 逾期", empty_hint: "暂时没有到期要补的", body: {} }], sources: [],
});
assert.ok(hinted.includes("暂时没有到期要补的"), "empty_hint 要原样显示");

// ── 4. `pending` 只能显示成「待核」,不许显示成判定或一个算出来的到期日 ──
const pending = renderProfile({
  display_name: "d", sources: [], sections: [{
    kind: "reminders", title: "t", empty_hint: null,
    body: { items: [{ id: "r1", action: "复查眼底", state: "overdue", overdue_days: 400, pending: true, basis: "label" }] },
  }],
});
assert.ok(pending.includes("待核"), "pending 要显示成「待核」");
assert.ok(!pending.includes("逾期"), "pending 不许显示成一档判定");
assert.ok(!pending.includes("400"), "pending 不许显示算出来的超期天数");

// ── 5. 载荷是「对方递过来的任意密文」:每一个字段都必须转义 ─────────────
// 严格 CSP 挡得住脚本执行,**挡不住往医生眼前塞一段假的医疗文字**(issue #143)。
const evil = '<img src=x onerror=alert(1)>';
const xss = renderProfile({
  display_name: evil, package_version: evil, disclaimer: evil,
  sources: [{ id: evil, cite: evil, url: null }],
  sections: [{
    kind: "checklist", title: evil, empty_hint: null,
    body: { states: [{ label: evil, verdict: "no", items: [{ label: evil, verdict: "no", actual: evil, actual_at: evil, source: evil, reason: evil }] }] },
  }],
});
assert.ok(!xss.includes("<img"), "载荷里的标签必须被转义,一个都不许落进 DOM");
assert.ok(xss.includes("&lt;img"), "转义后的原文应仍然看得见");

console.log("✓ renderProfile 冒烟自检通过");
