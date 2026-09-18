//! 病程档案的 FFI 门面。**规则全在 `packages/profile`**,这里只做几件事:验清单、
//! 把包收进缓存、装术语覆盖层、把保险箱投影成引擎的输入、把用户的动作记进保险箱。
//!
//! 函数名都以 `vault_profile_` 打头:FRB 派发表按**函数名**字典序编号,这个前缀
//! 排在 `recognize_image_pp` 之后,所以加函数不会挪动它的下标 44。
//!
//! 「44 不许动」这条**出自本 SDD 的 `global-constraints.md`**(它要求 codegen 之后
//! 逐字核对那一行),**不是**原生代码里的硬编码:核过 `ios/Runner/*.swift` 与安卓
//! Kotlin 侧,没有一处写死 FRB 序号;Dart 的 `funcId: 44`
//! (`lib/src/rust/frb_generated.dart`)与这里的 `44 =>` 出自同一次 codegen。
//! 约束照守,理由按实情写。有一条测试钉着:`rust/tests/frb_dispatch_indices.rs`。
//!
//! `dir` 一律是**包缓存目录**(`profile::cache_store` 在它下面建 `skills/`),不是
//! 保险箱根:包是公开的、签过名的、全成员共用的东西,不属于任何一个箱子。
use crate::api::vault_projections;
use std::path::Path;

/// 验清单的签名并原样交给 Dart。**Dart 永远不自己解析未验签的清单** —— 那是中间人
/// 改一行 `version` 就能拿去拼路径的地方(`lib/skill_packages.dart`)。
pub fn vault_profile_verify_index(envelope_json: String) -> anyhow::Result<String> {
    let idx = profile::load_signed_index(&envelope_json).map_err(|e| anyhow::anyhow!("{e}"))?;
    Ok(serde_json::to_string(&serde_json::json!({
        "skills": idx.skills.iter().map(|s| serde_json::json!({
            "id": s.id, "version": s.version, "min_engine": s.min_engine, "name": s.name
        })).collect::<Vec<_>>()
    }))?)
}

/// 装包,返回包 id。验签、引擎版本闸、单调版本闸(拒绝降级)全在
/// `profile::cache_store` 里,这里只把它的错误原样变成 Dart 读得到的一句话,**不吞**。
pub fn vault_profile_install_package(dir: String, envelope_json: String) -> anyhow::Result<String> {
    let dir = Path::new(&dir);
    let id = profile::cache_store(dir, &envelope_json).map_err(|e| anyhow::anyhow!("{e}"))?;
    // 覆盖层跟着装包走一遍:新版包可能改了别名或加了新分析物,而界面不一定马上
    // 重建视图。此刻没开箱(App 刚启动就刷包)就读不到动作日志 —— 那就保持原样,
    // 下一次 `vault_profile_view` 一定会重建。
    //
    // 只读动作日志那几份(`gather_profile_events`):覆盖层的输入只有事件,一整箱
    // 病历的正文与抽取结果在这条路上一份都用不上。
    if let Ok(events) = vault_projections::gather_profile_events() {
        terminology::set_overlay(overlay_entries(dir, &events));
    }
    Ok(id)
}

/// 算一份 `ProfileView` 并序列化给 Dart。**纯投影**:不写任何东西进保险箱。
///
/// `today` 取设备本地日期 —— 「今天该不该复查」是按用户所在时区的今天算的,
/// UTC 会让东八区的清晨算成昨天。
pub fn vault_profile_view(dir: String, package_id: String) -> anyhow::Result<String> {
    let dir = Path::new(&dir);
    // 先看有没有包:没有的话不必读一整箱病历,而这条路也不需要开着的保险箱
    // (装包早于开箱是正常顺序)。
    let pkg = profile::cache_load(dir, &package_id)
        .ok_or_else(|| anyhow::anyhow!("没有可用的病种包:{package_id}"))?;
    // **闸排在整箱逐份读之前。** 先只读动作日志那几份:没开启的话引擎一块都不算
    // (spec §4「从未开启 = 不算、不显示、不提醒」),那就没有任何理由去解一整箱
    // 病历的正文与抽取结果 —— 而「装上了还没开启」正是入口卡每次打开「趋势」都会
    // 走的那一态。
    let events = vault_projections::gather_profile_events()?;
    // 术语覆盖层必须在 `aggregate` **之前**装上(`materialize` 第一步就是它),
    // 否则 UPCR 这类包里新定义的分析物在分组那一步就已经落进「未识别」桶了。
    // 它的输入只有事件,与这份视图算不算得出来无关,所以两条路上都先装好 ——
    // 趋势页这些**不走病程档案**的界面也靠它认包里的新分析物。
    terminology::set_overlay(overlay_entries(dir, &events));
    if !profile::is_enabled(&events, &pkg.manifest.id) {
        // `materialize` 在关着时本来就不碰 `docs`(它直接给空 sections),所以这里
        // 传一个空切片得到的是**与全量读那条路逐字节相同**的一份「关着」的视图。
        let view = profile::materialize(&[], &events, &pkg, today());
        return Ok(serde_json::to_string(&view)?);
    }
    let input = vault_projections::gather_for_profile()?;
    // 动作日志那几份在这一趟里被读了第二次 —— 这是把闸提前的代价,几份合成文本,
    // 换掉的是「没开启也解一整箱病历」。
    let docs = input.source_docs();
    let view = profile::materialize(&docs, &input.events, &pkg, today());
    Ok(serde_json::to_string(&view)?)
}

/// 按**当前开着的保险箱**重装术语覆盖层(装着且开着的包的 `terms` 合并成一份)。
///
/// 覆盖层是**进程级全局**,而保险箱是一次一个:换成员之后不重装,上一个成员开的
/// 病种词典还挂在全局词典上。所以换箱那一侧先清空(`vault::open_vault` /
/// `vault_sync::sync_open_profile_vault` 成功换箱后各清一次),由开完箱的调用方
/// (`lib/vault_boot.dart`)再调本函数按新箱子重装 —— 于是趋势页这些**不走病程
/// 档案**的界面,也能在开机后就认得包里的新分析物,而不必等用户先点开档案页。
///
/// 没开箱 / 读不到动作日志时报错(调用方按「这次没装上」处理即可,别让它挡住开箱)。
pub fn vault_profile_refresh_terms(dir: String) -> anyhow::Result<()> {
    // 只读动作日志那几份:覆盖层的输入只有事件。这条路每次开箱都走一遍(开机、
    // 换成员),读一整箱正文只为了拿那几条事件是纯浪费。
    let events = vault_projections::gather_profile_events()?;
    terminology::set_overlay(overlay_entries(Path::new(&dir), &events));
    Ok(())
}

/// 记一条用户动作(开启/关闭某个病、确认诊断、记一次复发……),返回 document id。
///
/// 与 `add_note`/`add_self_measurement` **完全同一条路径**
/// (`vault::add_synthetic_document`):合成文本当"文件"过一遍 `import`,零新事件
/// 类型 —— 保险箱格式一个字节都不动,桌面照样读得懂、照样同步。
///
/// `at` 是**事件发生的那天**(用户说的那天,不是记录那天),必须是 `YYYY-MM-DD`:
/// 开关闸按它排序(`profile::is_enabled`),形状不对会悄悄排错,所以在这道边界上
/// 就挡住。`payload` 必须是 JSON **对象**:规则只按键取值,`null`/数组/裸数字对
/// 任何一条规则都只是噪音,别让它进日志。
///
/// **正文里必须有一行随记录时刻变的字节**(`记录时间:`,与自测记录同一手法,
/// `vault.rs` 的 `add_self_measurement_to`)。否则同 `(kind, package, at, payload)`
/// 的第二次记录会被 `Vault::import` 的 CAS 按**内容**去重,直接回传旧 document id、
/// 一条事件都不追加 —— 同一天「开→关→再开」就再也开不回来,而 FFI 还返回 `Ok`。
pub fn vault_profile_record_event(
    kind: String,
    package: String,
    at: String,
    payload_json: String,
) -> anyhow::Result<i64> {
    if chrono::NaiveDate::parse_from_str(&at, "%Y-%m-%d").is_err() {
        anyhow::bail!("事件日期必须是 YYYY-MM-DD,实际:{at}");
    }
    let payload: serde_json::Value = serde_json::from_str(&payload_json)?;
    if !payload.is_object() {
        anyhow::bail!("事件载荷必须是 JSON 对象(没有就传 {{}}),实际:{payload_json}");
    }
    let ev = parser::ProfileEvent {
        kind,
        package,
        at,
        payload,
    };
    // 一次时钟读数派生出三样东西,保证它们说的是同一刻:正文里那行记录时间、
    // 合成文件名、文档日期。
    let now = chrono::Local::now();
    let text = parser::render_profile_event_text(&human_lines(&ev, now), &ev);
    let title = format!("病程档案 · {}", kind_label(&ev.kind));
    let name = format!("profile-event-{}.txt", now.format("%Y%m%dT%H%M%S%.f"));
    // 文档日期存**本地墙上时间**(再贴 `Utc` 标签),与 `parse_measured_at` 给
    // 笔记/自测记录的存法逐字一致 —— 不然凌晨记的一条会在时间线上落到昨天。
    let when = now.naive_local().and_utc();
    crate::api::vault::with_state(|state| {
        crate::api::vault::add_synthetic_document(
            &state.vault,
            core_model::DocType::ProfileEvent,
            when,
            &name,
            title,
            Some("zh".into()),
            text,
        )
    })
}

/// 设备本地日期。
fn today() -> chrono::NaiveDate {
    chrono::Local::now().date_naive()
}

/// 动作日志正文里给人读的那几行(载荷行由 `parser::render_profile_event_text`
/// 接在后面)。文档正文会出现在时间线里,所以这里写的是人话,不是 JSON。
///
/// 「记录时间」带毫秒与时区偏移:它既是给人看的(这条是什么时候记的),也是让
/// **每一次记录的字节都唯一**的那一样东西 —— 理由见 [`vault_profile_record_event`]。
fn human_lines(ev: &parser::ProfileEvent, now: chrono::DateTime<chrono::Local>) -> Vec<String> {
    vec![
        kind_label(&ev.kind).to_string(),
        format!("病种:{}", ev.package),
        format!("日期:{}", ev.at),
        format!(
            "记录时间:{}",
            now.to_rfc3339_opts(chrono::SecondsFormat::Millis, false)
        ),
    ]
}

/// kind 的中文说法。**只有今天真的有入口会记的那两种有**:别的 kind(复发、症状分、
/// 停药……)要等 C5 的界面才开始记,让写那个入口的人顺手把自己那条的措辞加进来,
/// 比现在替他猜十种说法强。认不出的原样印 kind 本身,不编。
fn kind_label(kind: &str) -> &str {
    match kind {
        "enable" => "开启病程档案",
        "disable" => "关闭病程档案",
        other => other,
    }
}

// ─────────────────────────── 术语覆盖层 ───────────────────────────

/// 缓存目录里**装着**的全部包,按 id 排序(目录序不确定,而覆盖层里「同一个别名
/// 先到先得」,顺序必须是确定的)。读不出/验不过的那份跳过 —— `profile::cache_load`
/// 每次都重新验签,一份坏缓存不该挡住别的病。
fn installed_packages(dir: &Path) -> Vec<profile::Package> {
    let Ok(entries) = std::fs::read_dir(dir.join("skills")) else {
        return Vec::new();
    };
    let mut ids: Vec<String> = entries
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().into_string().ok()?;
            name.strip_suffix(".json").map(str::to_string)
        })
        .collect();
    ids.sort();
    ids.iter()
        .filter_map(|id| profile::cache_load(dir, id))
        .collect()
}

/// 装着**而且开着**的包,把它们的 `terms` 并成**一份**覆盖层条目表。
///
/// 两件事必须在这里做,`terminology::set_overlay` 一概不代管(见它的文档):
/// * **合并**:整体替换,分两次调用后一次会把前一包冲掉;
/// * **闸**:没开启的病不许把别名塞进全局词典(spec §4「从未开启 = 不算、不显示、
///   不提醒」)—— 闸用 `profile::is_enabled` 那一个实现,不在这儿照着重写一遍。
fn overlay_entries(dir: &Path, events: &[parser::ProfileEvent]) -> Vec<terminology::Entry> {
    let mut out: Vec<terminology::Entry> = Vec::new();
    for pkg in installed_packages(dir) {
        if !profile::is_enabled(events, &pkg.manifest.id) {
            continue;
        }
        for a in &pkg.terms.analytes {
            out.push(analyte_entry(a));
        }
        // `HashMap` 的迭代顺序每次都不一样;覆盖层「先到先得」,必须排定。
        let mut keys: Vec<&String> = pkg.terms.aliases.keys().collect();
        keys.sort();
        for key in keys {
            let aliases = &pkg.terms.aliases[key];
            match out.iter_mut().find(|e| &e.key == key) {
                // 这个 key 是同一个包刚定义的新分析物 —— 别名并进那一条,不另起。
                // 另起的那条没有定义(`overlay_match` 在内置里查不到 key 时就拿它
                // 当定义用),会盖掉刚刚给出的规范名/单位。
                Some(e) => e.aliases.extend(aliases.iter().cloned()),
                None => out.push(alias_only_entry(key, aliases)),
            }
        }
    }
    out
}

/// 一条只有别名、没有定义的覆盖层条目(`terms.aliases` 那一半:给**已有** key 加
/// 别名)。
///
/// `overlay_match` 命中之后,定义一律去内置词典按 `key` 查(内置有就用内置的),
/// 所以下面这些字段只是**内置里没有这个 key** 时的兜底:`canonical_name` 填 key
/// 本身,不替包编一个中文名,也不留空串(空串会被当成一个真的显示名印在屏上)。
fn alias_only_entry(key: &str, aliases: &[String]) -> terminology::Entry {
    terminology::Entry {
        key: key.to_string(),
        canonical_name: key.to_string(),
        // 包只会带化验项(体征是内置的,药走 `normalize_drug` 那条路)。让包自己
        // 声明 category 就等于把「一个化验项能不能冒充处方名」交给包作者决定。
        category: terminology::Category::Lab,
        system: None,
        panel: None,
        codes: terminology::Codes::default(),
        canonical_unit: None,
        units: Vec::new(),
        ingredient: None,
        aliases: aliases.to_vec(),
        // OCR 混淆表是人工核过的误读对照,包不带这种东西。
        ocr_confusions: Vec::new(),
        note: None,
    }
}

/// 包里**新定义**的分析物(词典里没有的,如 UPCR)→ 词典条目。
fn analyte_entry(a: &profile::Analyte) -> terminology::Entry {
    let mut e = alias_only_entry(&a.key, &a.aliases);
    e.canonical_name = a.name.clone();
    e.panel = a.panel.clone();
    e.codes.loinc = a.loinc.clone();
    e.canonical_unit = a.canonical_unit.clone();
    e.units = a
        .units
        .iter()
        .map(|u| terminology::UnitConversion {
            unit: u.unit.clone(),
            slope: u.slope,
            intercept: u.intercept,
        })
        .collect();
    e.note = a.note.clone();
    e
}

#[cfg(test)]
mod tests {
    use super::*;
    // 端到端用例开的是进程级 `api::vault::VAULT`(和生产一样一次只有一个箱子),
    // 而术语覆盖层同样是进程级全局 —— 两样都得串行化,用全 crate 共享的那把锁。
    use crate::api::vault::VAULT_TEST_LOCK as TEST_LOCK;

    /// 仓库里**真的那份**签好的包与清单(生产公钥签的)。测试不自己造密钥:
    /// 私钥不在仓库里(`~/.medme_skill_signing_key`),而这两份文件正是线上
    /// `GET /v1/skills/*` 会返回的字节,拿它们当夹具等于顺手钉住「App 装得上我们
    /// 自己发的包」。
    const SLE_PACKAGE: &str = include_str!("../../../../../skills/sle/2026.09.1.json");
    const SKILLS_INDEX: &str = include_str!("../../../../../skills/index.json");

    fn ev(kind: &str, at: &str) -> parser::ProfileEvent {
        parser::ProfileEvent {
            kind: kind.into(),
            package: "sle".into(),
            at: at.into(),
            payload: serde_json::json!({}),
        }
    }

    fn open_temp_vault(home: &std::path::Path) {
        crate::api::vault::open_vault(
            home.join("docs").to_string_lossy().to_string(),
            home.join("data").to_string_lossy().to_string(),
            None,
        )
        .unwrap();
    }

    #[test]
    fn installing_a_tampered_package_fails_and_leaves_no_cache_file() {
        let dir = tempfile::tempdir().unwrap();
        let bad = r#"{"sig":"AAAA","package":"{}"}"#;
        assert!(
            vault_profile_install_package(dir.path().display().to_string(), bad.into()).is_err()
        );
        assert!(!dir.path().join("skills").exists());
    }

    #[test]
    fn view_without_an_installed_package_reports_it_instead_of_panicking() {
        let dir = tempfile::tempdir().unwrap();
        let err = vault_profile_view(dir.path().display().to_string(), "sle".into()).unwrap_err();
        assert!(err.to_string().contains("没有可用的病种包"), "{err}");
    }

    #[test]
    fn the_repo_index_verifies_and_lists_the_sle_package() {
        let json = vault_profile_verify_index(SKILLS_INDEX.into()).expect("仓库里的清单要验得过");
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        let first = &v["skills"][0];
        assert_eq!(first["id"], "sle");
        assert_eq!(first["version"], "2026.09.1");
        assert_eq!(first["min_engine"], 1);
    }

    #[test]
    fn a_tampered_index_is_refused_so_nobody_can_redirect_the_fetcher() {
        // 中间人把 version 改成别的号:客户端照着拼路径就会去拉一个我们没发过的
        // 文件。签名在这儿挡住,所以 Dart 那边永远拿不到「验过的 version」。
        let tampered = SKILLS_INDEX.replace("2026.09.1", "2026.09.9");
        assert!(tampered != SKILLS_INDEX, "改写必须真的发生");
        assert!(vault_profile_verify_index(tampered).is_err());
    }

    #[test]
    fn a_malformed_event_date_is_refused_at_the_ffi_boundary() {
        // 形状不对的 `at` 会让开关闸(按 `at` 字典序取最新)悄悄排错 —— 在边界上挡,
        // 不落进保险箱。这条不需要开箱:校验排在写入之前。
        let err = vault_profile_record_event(
            "enable".into(),
            "sle".into(),
            "2026/01/01".into(),
            "{}".into(),
        )
        .unwrap_err();
        assert!(err.to_string().contains("YYYY-MM-DD"), "{err}");
    }

    #[test]
    fn recording_enable_then_disable_flips_the_gate_in_the_view() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        open_temp_vault(home.path());
        let dir = home.path().join("skills-cache");
        let dir_s = dir.display().to_string();
        assert_eq!(
            vault_profile_install_package(dir_s.clone(), SLE_PACKAGE.into()).unwrap(),
            "sle"
        );

        let parse = |json: String| serde_json::from_str::<serde_json::Value>(&json).unwrap();

        // 从没开启过 = 关着:出得来一份视图(界面要拿它的名字/免责声明画入口卡),
        // 但一块都不算(spec §4)。
        let before = parse(vault_profile_view(dir_s.clone(), "sle".into()).unwrap());
        assert_eq!(before["package_id"], "sle");
        assert_eq!(before["package_version"], "2026.09.1");
        assert_eq!(before["display_name"], "系统性红斑狼疮");
        assert_eq!(before["enabled"], false);
        assert_eq!(before["sections"].as_array().unwrap().len(), 0);
        assert!(!before["disclaimer"].as_str().unwrap().is_empty());

        let id = vault_profile_record_event(
            "enable".into(),
            "sle".into(),
            "2026-01-01".into(),
            "{}".into(),
        )
        .unwrap();
        assert!(id > 0);
        // 文档正文既能给人读,也能被原样解回载荷(动作日志的两半)。
        let text = crate::api::vault::get_document(id).unwrap().ocr_text;
        assert!(text.starts_with("开启病程档案"), "{text}");
        let back = parser::parse_profile_event_payload(&text).expect("载荷要解得回来");
        assert_eq!(
            (back.kind.as_str(), back.package.as_str()),
            ("enable", "sle")
        );
        assert_eq!(back.at, "2026-01-01");

        let on = parse(vault_profile_view(dir_s.clone(), "sle".into()).unwrap());
        assert_eq!(on["enabled"], true);
        assert!(
            !on["sections"].as_array().unwrap().is_empty(),
            "开着就该出卡片(空数据的那几块自带 empty_hint)"
        );

        vault_profile_record_event(
            "disable".into(),
            "sle".into(),
            "2026-02-01".into(),
            "{}".into(),
        )
        .unwrap();
        let off = parse(vault_profile_view(dir_s, "sle".into()).unwrap());
        assert_eq!(off["enabled"], false);
        assert_eq!(off["sections"].as_array().unwrap().len(), 0);

        terminology::set_overlay(Vec::new());
    }

    /// 闸排在整箱逐份读之前 —— 没开启就一份临床正文都不读。
    ///
    /// 这条是**代价**测试,不是功能测试:关着的那份视图本来就长这样(上一条已经
    /// 钉过),这里钉的是「拿到它花了多少」。入口卡在「装上了还没开启」这一态下
    /// 每次打开「趋势」都会走这条路,读一整箱病历只为了发现「没开启」是纯浪费。
    #[test]
    fn a_disabled_package_reads_no_clinical_document_at_all() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        open_temp_vault(home.path());
        let dir_s = home.path().join("skills-cache").display().to_string();
        vault_profile_install_package(dir_s.clone(), SLE_PACKAGE.into()).unwrap();

        // 箱里放一份真的临床文档 —— 逐份读的时候它就是最贵的那一类。
        crate::api::vault::add_note("今天血压 130/80".into(), None).unwrap();

        let parse = |json: String| serde_json::from_str::<serde_json::Value>(&json).unwrap();

        // ① 从没开启过:一份正文都没读,视图照样出得来(入口卡要拿它的名字)。
        vault_projections::reset_doc_text_reads();
        let off = parse(vault_profile_view(dir_s.clone(), "sle".into()).unwrap());
        assert_eq!(off["enabled"], false);
        assert_eq!(off["sections"].as_array().unwrap().len(), 0);
        assert_eq!(off["display_name"], "系统性红斑狼疮");
        assert_eq!(
            vault_projections::doc_text_reads(),
            0,
            "没开启就不该读任何一份正文(箱里那份笔记一次都不该被解开)"
        );

        // ② 开启之后:动作日志那份 + 笔记那份都读到了。3 = 闸那一趟读动作日志
        //    (1)+ 全量那一趟读两份(2);动作日志被读两次就是把闸提前的代价。
        vault_profile_record_event(
            "enable".into(),
            "sle".into(),
            "2026-01-02".into(),
            "{}".into(),
        )
        .unwrap();
        vault_projections::reset_doc_text_reads();
        let on = parse(vault_profile_view(dir_s, "sle".into()).unwrap());
        assert_eq!(on["enabled"], true);
        assert!(!on["sections"].as_array().unwrap().is_empty());
        assert_eq!(vault_projections::doc_text_reads(), 3);

        terminology::set_overlay(Vec::new());
    }

    #[test]
    fn an_enabled_package_adds_both_halves_of_its_terms_to_the_overlay() {
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let dir = tempfile::tempdir().unwrap();
        vault_profile_install_package(dir.path().display().to_string(), SLE_PACKAGE.into())
            .unwrap();
        let entries = overlay_entries(dir.path(), &[ev("enable", "2026-01-01")]);

        // 别名那一半(`terms.aliases`):内置已经有 complement_c3,包只给它加别名。
        let c3 = entries
            .iter()
            .find(|e| e.key == "complement_c3")
            .expect("别名条目要在覆盖层里");
        assert!(c3.aliases.contains(&"血清补体C3".to_string()));
        // 新分析物那一半(`terms.analytes`):词典里没有,定义整条来自包。
        let hpf = entries
            .iter()
            .find(|e| e.key == "urine_rbc_hpf")
            .expect("新分析物要在覆盖层里");
        assert_eq!(hpf.canonical_name, "尿红细胞(高倍视野)");
        assert_eq!(hpf.canonical_unit.as_deref(), Some("/[HPF]"));

        // 真装上之后查得到,**而且定义仍来自内置**(包能加别名、改不掉定义)。
        terminology::set_overlay(entries);
        let m = terminology::normalize("血清补体C3").expect("包的别名要查得到");
        assert_eq!(m.key, "complement_c3");
        assert_eq!(
            m.canonical_name,
            terminology::entry_for("complement_c3")
                .unwrap()
                .canonical_name,
            "显示名必须是内置那条的,不是包说的"
        );
        let up = terminology::normalize("镜检红细胞").expect("包新定义的分析物要查得到");
        assert_eq!(up.key, "urine_rbc_hpf");
        terminology::set_overlay(Vec::new());
    }

    #[test]
    fn a_package_that_was_never_enabled_contributes_nothing_to_the_overlay() {
        // spec §4:从未开启 = 不算、不显示、不提醒 —— 也包括「别往全局词典里塞词」。
        let dir = tempfile::tempdir().unwrap();
        vault_profile_install_package(dir.path().display().to_string(), SLE_PACKAGE.into())
            .unwrap();
        assert!(overlay_entries(dir.path(), &[]).is_empty());
        assert!(overlay_entries(dir.path(), &[ev("disable", "2026-01-01")]).is_empty());
    }

    #[test]
    fn toggling_three_times_on_the_same_day_ends_enabled_and_leaves_three_documents() {
        // 回归(fix round 1 · C1):正文里没有随记录时刻变的字节时,第三次
        // `enable(at=D)` 与第一次逐字节相同 → `Vault::import` 的 CAS 去重 → 回传旧
        // document id、**一条事件都不追加**,于是 events 永远停在 [enable, disable],
        // 用户当天再也开不回来,而 FFI 还返回 Ok。
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        open_temp_vault(home.path());
        let dir_s = home.path().join("skills-cache").display().to_string();
        vault_profile_install_package(dir_s.clone(), SLE_PACKAGE.into()).unwrap();

        let same_day = "2026-03-01";
        let mut ids = Vec::new();
        for kind in ["enable", "disable", "enable"] {
            ids.push(
                vault_profile_record_event(kind.into(), "sle".into(), same_day.into(), "{}".into())
                    .unwrap(),
            );
        }
        let uniq: std::collections::HashSet<_> = ids.iter().collect();
        assert_eq!(uniq.len(), 3, "三次记录要是三份文档,实际 {ids:?}");
        // document_id 升序 = 追加顺序 = `gather_for_profile` 给引擎的顺序,
        // 于是「同一天里最后那条说了算」。
        assert!(ids[0] < ids[1] && ids[1] < ids[2], "{ids:?}");

        let view: serde_json::Value =
            serde_json::from_str(&vault_profile_view(dir_s, "sle".into()).unwrap()).unwrap();
        assert_eq!(view["enabled"], true, "同日开→关→再开,最后是开着");

        crate::api::vault::clear_terminology_overlay();
    }

    #[test]
    fn the_last_event_of_the_day_wins_even_when_it_is_the_off_one() {
        // 上面那条是**回文**(开→关→开):把顺序整个倒过来,答案还是「开着」,
        // 所以它证不了「同一天里最后那条说了算」。这条不对称:开→关,倒过来读
        // 就会答「开着」(终审 M5)。
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let home = tempfile::tempdir().unwrap();
        open_temp_vault(home.path());
        let dir_s = home.path().join("skills-cache").display().to_string();
        vault_profile_install_package(dir_s.clone(), SLE_PACKAGE.into()).unwrap();

        let same_day = "2026-03-01";
        for kind in ["enable", "disable"] {
            vault_profile_record_event(kind.into(), "sle".into(), same_day.into(), "{}".into())
                .unwrap();
        }
        let view: serde_json::Value =
            serde_json::from_str(&vault_profile_view(dir_s, "sle".into()).unwrap()).unwrap();
        assert_eq!(view["enabled"], false, "同日开→关,最后是关着");

        crate::api::vault::clear_terminology_overlay();
    }

    #[test]
    fn a_non_object_payload_is_refused_at_the_ffi_boundary() {
        // 规则只按键取值:`null`/数组/裸数字进了日志也只是噪音。不开箱也该被挡住。
        for bad in ["null", "[1,2]", "3", "\"x\""] {
            let err = vault_profile_record_event(
                "flare".into(),
                "sle".into(),
                "2026-01-01".into(),
                bad.into(),
            )
            .unwrap_err();
            assert!(err.to_string().contains("JSON 对象"), "{bad}: {err}");
        }
    }

    #[test]
    fn opening_another_members_vault_clears_the_overlay() {
        // 覆盖层是进程级全局,保险箱一次只开一个:A 开着狼疮,切到 B 之后 B 的
        // 化验识别不许还认得狼疮包里的词(spec §4 在跨成员这一侧的落点)。
        let _guard = TEST_LOCK.lock().unwrap_or_else(|p| p.into_inner());
        let a = tempfile::tempdir().unwrap();
        open_temp_vault(a.path());
        let dir_s = a.path().join("skills-cache").display().to_string();
        vault_profile_install_package(dir_s.clone(), SLE_PACKAGE.into()).unwrap();
        vault_profile_record_event(
            "enable".into(),
            "sle".into(),
            "2026-01-01".into(),
            "{}".into(),
        )
        .unwrap();
        vault_profile_refresh_terms(dir_s.clone()).unwrap();
        assert_eq!(
            terminology::normalize("镜检红细胞").map(|m| m.key),
            Some("urine_rbc_hpf".to_string()),
            "A 的箱子开着狼疮:包里的新分析物应当查得到"
        );

        // 切成员(同一个进程,另一个箱子)。
        let b = tempfile::tempdir().unwrap();
        open_temp_vault(b.path());
        assert!(
            terminology::normalize("镜检红细胞").is_none(),
            "换箱之后覆盖层必须退回内置"
        );

        // B 自己没开过任何病 —— 重装一次也还是空的(装着不等于开着)。
        vault_profile_refresh_terms(dir_s).unwrap();
        assert!(terminology::normalize("镜检红细胞").is_none());
    }
}
