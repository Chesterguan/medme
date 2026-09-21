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
  // 摘要那块也要跑:它与病程档案画在**同一页**上,参考区间必须是同一套说法。
  slice("function buildEMRFromSummary", "function wireSummary"),
  slice("// ── 病程档案(Task 23)", "function render(payload) {"),
  "return { renderProfile, renderSummary };",
].join("\n");
// eslint-disable-next-line no-new-func -- 这就是本文件的全部意义:跑查看器里那段真源码。
const { renderProfile, renderSummary } = new Function(src)();

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

// 记号与标签必须**贴在一起**。只用 includes 查「✔」「✘」各出现过,把渲染结果里
// 每一个 ✘ 换成 ✔ 也照样全绿 —— 三态诚实正是这块最该守的东西,量具不能漏它。
const adjacency = [
  ['<span class="pf-mk ok">✔</span><div class="pf-bd"><div class="pf-lb">低补体', '满足的那条要挂 ✔'],
  ['<span class="pf-mk no">✘</span><div class="pf-bd"><div class="pf-lb">dsDNA 升高', '未满足的那条要挂 ✘'],
  ['<span class="pf-mk no">✘</span><div class="pf-bd"><div class="pf-lb">泼尼松/泼尼松龙(或等效)&lt; 5 mg/天', '达标表未满足的那条要挂 ✘'],
  ['<span class="pf-mk un">?</span><div class="pf-bd"><div class="pf-lb">医生整体评估', '未知的那条要挂 ?'],
];
for (const [frag, why] of adjacency) assert.ok(out.includes(frag), why);

// 包里每一条「与指南口径有差」的话(`note`)都必须印出来(终审 I3):`gfr_80_baseline`
// 比的是「最近一次 ÷ 最早一次」而不是原文的「前 3 个月内」,`mmf_cbc` 第一年之后那一档
// 是包作者的外推 —— 引擎特意把这两句原样带到渲染层,最后一米丢掉的话,医生读到的就是
// 一个没有限定语的结论。
for (const [frag, why] of [
  ["基线 = 档案里最早一次有日期的 eGFR", "里程碑条目的 note 要印出来"],
  ["第一年之后说明书没再给任何间隔", "提醒条目的 note 要印出来"],
]) assert.ok(out.includes(frag), why);

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

// ── 6. 时间轴:没有日期的事件必须自己一组,不许挂在最近那个年份底下 ───────
const tl = renderProfile({
  display_name: "d", sources: [], sections: [{
    kind: "timeline", title: "病程时间轴", empty_hint: null,
    body: {
      years: [{ year: 2026, events: [{ type: "flare", text: "皮疹加重", date: "2026-03-01", severity: "high" }] }],
      undated: [{ type: "biopsy", text: "肾活检" }],
    },
  }],
});
assert.ok(tl.includes('<div class="pf-grp">日期不详</div>'), "无日期事件要有自己的分组头");
assert.ok(tl.includes("肾活检"), "分组头不是把它藏起来的借口");
assert.ok(tl.indexOf("日期不详") > tl.indexOf("皮疹加重"), "分组头排在有日期那组之后");
assert.ok(tl.indexOf("日期不详") < tl.indexOf("肾活检"), "分组头排在无日期那条之前");

// ── 7. `handoff`:引擎今天一块都不产,这个分支什么都不画(但它有名字) ────
assert.equal(
  renderProfile({ display_name: "d", sources: [], sections: [{ kind: "handoff", title: "给医生看", body: { blocks: [] } }] }),
  "",
  "handoff 今天不画;等引擎真产出这一块时改 pfSection 里那一行",
);

// ── 8. 摘要与病程档案画在同一页,参考区间必须是同一套说法 ────────────────
// 老写法 `refLow != null ? "≥"+refLow : …` 会把 CRP 0–5、抗 dsDNA 0–30 这类
// **下限为 0** 的区间印成「参考 ≥0」,等于告诉医生这条线没有上限。
const summaryOut = renderSummary({
  problems: [{
    term: "系统性红斑狼疮", onset: "2024-03", status: "稳定",
    labs: [
      { name: "C反应蛋白", unit: "mg/L", refLow: 0, refHigh: 30, pts: [["2026-03", 8.1], ["2026-09", 3.2]] },
      { name: "两头都没有的指标", unit: "U", pts: [["2026-09", 1]] },
    ],
  }],
}, "2026-09-16", { name: "张三" });
// 断在**渲染出来的那一段**上,不数全文里「参考」出现几次 —— 摘要末尾那句
// 「供参考、以原件为准」也含这两个字,数出来的是另一个问题的答案。
assert.ok(
  summaryOut.includes('<div class="rn">C反应蛋白</div><div class="rf">参考 0–30 mg/L</div>'),
  "摘要也要两头都说",
);
assert.ok(!summaryOut.includes("参考 ≥0"), "「参考 ≥0」是一句不实的话");
assert.ok(
  summaryOut.includes('<div class="rn">两头都没有的指标</div><div class="rf">U</div>'),
  "两头都没有的那条不该印出一个光秃秃的「参考 」",
);

console.log("✓ renderProfile 冒烟自检通过");
