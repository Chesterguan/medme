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

#[test]
fn an_event_for_another_package_does_not_enable_this_one() {
    let events = vec![parser::ProfileEvent {
        kind: "enable".into(),
        package: "ms".into(),
        at: "2026-03-01".into(),
        payload: serde_json::json!({}),
    }];
    assert!(!profile::materialize(&[], &events, &minimal_pkg(), day("2026-09-16")).enabled);
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
