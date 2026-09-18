//! 病程档案的 FFI 门面。**规则全在 `packages/profile`**,这里只做四件事:验清单、
//! 把包收进缓存、把保险箱投影成引擎的输入、把用户的动作记进保险箱。
//!
//! 函数名都以 `vault_profile_` 打头:FRB 派发表按**函数名**字典序编号,这个前缀
//! 排在 `recognize_image_pp`(下标 44,iOS AppDelegate 钉死的外部契约)之后,所以
//! 加函数不会把它挪走。有一条测试钉着,见 `rust/tests/frb_dispatch_indices.rs`。
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
    // ponytail: 为了拿动作日志顺手读了一整箱正文(`gather_for_profile`),而这里
    // 只要 `profile_event` 那几份。装包是一天最多几次的冷路径,与趋势页每次打开
    // 跑的是同一个读,不值得为它再开一条只取一种 doc_type 的取数路径。真慢了再说。
    if let Ok(input) = vault_projections::gather_for_profile() {
        terminology::set_overlay(overlay_entries(dir, &input.events));
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
    let input = vault_projections::gather_for_profile()?;
    // 术语覆盖层必须在 `aggregate` **之前**装上(`materialize` 第一步就是它),
    // 否则 UPCR 这类包里新定义的分析物在分组那一步就已经落进「未识别」桶了。
    terminology::set_overlay(overlay_entries(dir, &input.events));
    let docs = input.source_docs();
    let view = profile::materialize(&docs, &input.events, &pkg, today());
    Ok(serde_json::to_string(&view)?)
}

/// 记一条用户动作(开启/关闭某个病、确认诊断、记一次复发……),返回 document id。
///
/// 与 `add_note`/`add_self_measurement` **完全同一条路径**
/// (`vault::add_synthetic_document`):合成文本当"文件"过一遍 `import`,零新事件
/// 类型 —— 保险箱格式一个字节都不动,桌面照样读得懂、照样同步。
///
/// `at` 是**事件发生的那天**(用户说的那天,不是记录那天),必须是 `YYYY-MM-DD`:
/// 开关闸按它排序(`profile::is_enabled`),形状不对会悄悄排错,所以在这道边界上
/// 就挡住。
///
/// 同一天、同一 kind、同一 payload 记两次会被 CAS 去重成**同一份文档**(字节逐字
/// 相同)。这不是 bug:`at` 只到天,两条一模一样的记录本来就分不出先后,而闸读的
/// 是「最新那条是什么」,结果一样。
pub fn vault_profile_record_event(
    kind: String,
    package: String,
    at: String,
    payload_json: String,
) -> anyhow::Result<i64> {
    if chrono::NaiveDate::parse_from_str(&at, "%Y-%m-%d").is_err() {
        anyhow::bail!("事件日期必须是 YYYY-MM-DD,实际:{at}");
    }
    let ev = parser::ProfileEvent {
        kind,
        package,
        at,
        payload: serde_json::from_str(&payload_json)?,
    };
    let text = parser::render_profile_event_text(&human_lines(&ev), &ev);
    let title = format!("病程档案 · {}", kind_label(&ev.kind));
    let when = chrono::Utc::now();
    let name = format!("profile-event-{}.txt", when.format("%Y%m%dT%H%M%S%.f"));
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
fn human_lines(ev: &parser::ProfileEvent) -> Vec<String> {
    vec![
        kind_label(&ev.kind).to_string(),
        format!("病种:{}", ev.package),
        format!("日期:{}", ev.at),
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
}
