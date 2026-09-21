//! 开启闸:**从未开启的病,一个字都不显示、不算、不提醒**(spec §4)。
use chrono::NaiveDate;

mod common;
use common::{minimal_pkg, sle_like_doc};

fn day(s: &str) -> NaiveDate {
    s.parse().unwrap()
}

#[test]
fn a_package_that_was_never_enabled_yields_a_disabled_view_with_no_sections() {
    let text = sle_like_doc();
    let docs = vec![parser::SourceDoc {
        index: 0,
        date: Some(day("2026-09-01")),
        text: &text,
        doc_type: Some("lab_report".into()),
        title: None,
        extraction_json: None,
    }];
    let v = profile::materialize(&docs, &[], &minimal_pkg(), day("2026-09-16"));
    assert!(!v.enabled);
    assert!(
        v.sections.is_empty(),
        "没开启就什么都不算,连空 section 都不给"
    );
}

#[test]
fn enable_then_disable_leaves_it_disabled() {
    let ev = |kind: &str, at: &str| parser::ProfileEvent {
        kind: kind.into(),
        package: "t".into(),
        at: at.into(),
        payload: serde_json::json!({}),
    };
    let events = vec![ev("enable", "2026-03-01"), ev("disable", "2026-08-01")];
    let v = profile::materialize(&[], &events, &minimal_pkg(), day("2026-09-16"));
    assert!(!v.enabled);

    let events = vec![
        ev("enable", "2026-03-01"),
        ev("disable", "2026-08-01"),
        ev("enable", "2026-09-10"),
    ];
    let v = profile::materialize(&[], &events, &minimal_pkg(), day("2026-09-16"));
    assert!(v.enabled, "最后一条才算数");
}

/// 同一天连点两下开关:`at` 只到天,分不出先后,只能信 `events` 的顺序 ——
/// 它按保险箱事件日志的追加顺序给,所以靠后的那条就是后发生的。
#[test]
fn on_the_same_day_the_later_event_in_the_log_wins() {
    let ev = |kind: &str| parser::ProfileEvent {
        kind: kind.into(),
        package: "t".into(),
        at: "2026-09-16".into(),
        payload: serde_json::json!({}),
    };
    let today = day("2026-09-16");

    let opened_then_closed = vec![ev("enable"), ev("disable")];
    assert!(
        !profile::materialize(&[], &opened_then_closed, &minimal_pkg(), today).enabled,
        "同一天开了又关,最后是关着"
    );

    let closed_then_opened = vec![ev("disable"), ev("enable")];
    assert!(
        profile::materialize(&[], &closed_then_opened, &minimal_pkg(), today).enabled,
        "同一天关了又开,最后是开着"
    );
}

#[test]
fn an_event_for_another_package_does_not_affect_this_one() {
    let other = |kind: &str, at: &str| parser::ProfileEvent {
        kind: kind.into(),
        package: "ms".into(),
        at: at.into(),
        payload: serde_json::json!({}),
    };
    let today = day("2026-09-16");

    let events = vec![other("enable", "2026-03-01")];
    assert!(!profile::materialize(&[], &events, &minimal_pkg(), today).enabled);

    // 别的病后来关了(`at` 更晚),不能顺手把这个病也关掉 —— 一个保险箱可以同时开多个病。
    let events = vec![
        parser::ProfileEvent {
            kind: "enable".into(),
            package: "t".into(),
            at: "2026-03-01".into(),
            payload: serde_json::json!({}),
        },
        other("disable", "2026-09-10"),
    ];
    assert!(profile::materialize(&[], &events, &minimal_pkg(), today).enabled);
}

#[test]
fn an_enabled_view_carries_the_manifest_identity_and_sources() {
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "t".into(),
        at: "2026-03-01".into(),
        payload: serde_json::json!({}),
    }];
    let v = profile::materialize(&[], &events, &minimal_pkg(), day("2026-09-16"));
    assert!(v.enabled);
    assert_eq!(v.package_id, "t");
    assert_eq!(v.package_version, "2026.09.1");
    assert_eq!(v.display_name, "测试病");
    assert!(
        !v.disclaimer.is_empty(),
        "免责声明必须随视图一起出去,不能只在包里躺着"
    );
    assert_eq!(v.sources[0].id, "S1");
}
