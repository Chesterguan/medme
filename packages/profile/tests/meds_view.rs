//! 「用药」tab 的视图(2026-10-23 spec §5):最近 / 更早按 180 天与原文停药切分,更早带剂量链,
//! 过敏在同一本依据簿里引出处。
mod common;

use common::{corpus_docs, load_jane};

const TODAY: &str = "2026-10-22";

fn meds_json(docs: &[parser::SourceDoc<'_>], today: &str) -> serde_json::Value {
    let view = profile::materialize_meds(docs, &[], today.parse().unwrap());
    serde_json::to_value(&view).unwrap()
}

fn row<'a>(list: &'a serde_json::Value, name: &str) -> Option<&'a serde_json::Value> {
    list.as_array().unwrap().iter().find(|r| r["name"] == name)
}

#[test]
fn recent_and_earlier_split_by_stale_and_written_discontinuation() {
    let corpus = load_jane();
    let docs = corpus_docs(&corpus);
    let v = meds_json(&docs, TODAY);
    assert_eq!(v["stale_after_days"], 180);
    // 伏立康唑:病历写了 discontinued → 永远在「更早」,且剂量链末尾是停药节点。
    assert!(row(&v["recent"], "伏立康唑").is_none());
    let vori = row(&v["earlier"], "伏立康唑").expect("伏立康唑在更早");
    assert!(vori["stopped"]["at"].is_string());
    let nodes = vori["nodes"].as_array().unwrap();
    assert_eq!(nodes.last().unwrap()["kind"], "stopped");
    assert!(nodes.last().unwrap()["text"]
        .as_str()
        .unwrap()
        .contains("discontinued"));
    // 华法林:最近记录 2026-09;剂量链 5mg → 4mg。
    let w = row(&v["recent"], "华法林").expect("华法林在最近");
    assert_eq!(w["dose"], "4mg");
    assert_eq!(w["since"], "2025-01-14");
    assert!(row(&v["earlier"], "华法林").is_none());
    assert!(w.get("nodes").is_some(), "最近的药也带剂量链");
    let change = w["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .find(|n| n["kind"] == "change")
        .expect("有 change 节点");
    // 节点存原文剂量串(「5mg qd」),不是剂量键。
    assert!(
        change["from"].as_str().unwrap().starts_with("5mg"),
        "{change}"
    );
    assert!(
        change["to"].as_str().unwrap().starts_with("4mg"),
        "{change}"
    );
    assert!(w["raw_names"].as_array().unwrap().iter().any(|n| n
        .as_str()
        .unwrap()
        .to_lowercase()
        .contains("warfarin")));
    assert!(w["drug_key"].is_string());
    // 排序:两边都按最近记录日倒序。
    for list in [&v["recent"], &v["earlier"]] {
        let dates: Vec<&str> = list
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|r| r["last_seen"].as_str())
            .collect();
        let mut sorted = dates.clone();
        sorted.sort_by(|a, b| b.cmp(a));
        assert_eq!(dates, sorted);
    }
}

#[test]
fn stale_boundary_moves_a_drug_between_recent_and_earlier() {
    let corpus = load_jane();
    let docs = corpus_docs(&corpus);
    let v = meds_json(&docs, TODAY);
    let last: chrono::NaiveDate = row(&v["recent"], "美托洛尔").expect("美托洛尔在最近")
        ["last_seen"]
        .as_str()
        .unwrap()
        .parse()
        .unwrap();
    let at = |days: i64| {
        let today = (last + chrono::Duration::days(days)).to_string();
        meds_json(&docs, &today)
    };
    assert!(row(&at(179)["recent"], "美托洛尔").is_some());
    assert!(
        row(&at(180)["recent"], "美托洛尔").is_some(),
        "刚好 180 天仍算最近"
    );
    let v = at(181);
    assert!(row(&v["recent"], "美托洛尔").is_none());
    assert!(row(&v["earlier"], "美托洛尔").is_some());
}

#[test]
fn stopped_then_resumed_is_recent() {
    let raw = [
        ("2025-02-01", "处方\n美托洛尔 25mg qd\n".to_string()),
        ("2025-03-01", "处方\n美托洛尔 discontinued\n".to_string()),
        ("2025-09-01", "处方\n美托洛尔 25mg qd\n".to_string()),
    ];
    let docs = common::mk_docs(&raw);
    let v = meds_json(&docs, "2025-09-10");
    let m = row(&v["recent"], "美托洛尔").expect("停后又出现 → 最近");
    assert!(m.get("stopped").is_none());
    let kinds: Vec<&str> = m["nodes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|n| n["kind"].as_str().unwrap())
        .collect();
    assert_eq!(kinds, vec!["first", "stopped", "first"]);
}

#[test]
fn allergies_are_cited_from_the_documents_that_mention_them() {
    let mut corpus = load_jane();
    let table = "\nAllergies\nAllergen                      Reactions\n • Penicillin                 Rash\n • Latex  \n\nHome Medications:\n";
    corpus[0].text.push_str(table);
    corpus[1].text.push_str(table);
    let docs = corpus_docs(&corpus);
    let v = meds_json(&docs, TODAY);
    let al = v["allergies"].as_array().unwrap();
    assert_eq!(al.len(), 2, "{al:?}");
    let pen = al.iter().find(|a| a["substance"] == "Penicillin").unwrap();
    assert_eq!(pen["reaction"], "Rash");
    assert_eq!(
        pen["evidence"].as_array().unwrap().len(),
        2,
        "两份文档各一条依据"
    );
    let ev = v["evidence"].as_array().unwrap();
    for id in pen["evidence"].as_array().unwrap() {
        let e = ev.iter().find(|e| e["id"] == *id).expect("依据查得到");
        assert!(e["quote"].as_str().unwrap().contains("Penicillin"));
        assert_eq!(e["verified"], true);
    }
}

#[test]
fn every_evidence_id_in_the_meds_view_resolves() {
    let corpus = load_jane();
    let docs = corpus_docs(&corpus);
    let v = meds_json(&docs, TODAY);
    let ids: std::collections::HashSet<String> = v["evidence"]
        .as_array()
        .unwrap()
        .iter()
        .map(|e| e["id"].as_str().unwrap().to_string())
        .collect();
    let body = serde_json::to_string(
        &serde_json::json!({"r": v["recent"], "e": v["earlier"], "a": v["allergies"]}),
    )
    .unwrap();
    let mut n = 0;
    for (i, _) in body.match_indices("\"ev:") {
        let rest = &body[i + 1..];
        let id = &rest[..rest.find('"').unwrap()];
        assert!(ids.contains(id), "{id} 查不到");
        n += 1;
    }
    assert!(n > 0);
}

#[test]
fn empty_vault_gives_empty_lists_not_an_error() {
    let v = meds_json(&[], TODAY);
    assert!(v["recent"].as_array().unwrap().is_empty());
    assert!(v["earlier"].as_array().unwrap().is_empty());
    assert!(v["allergies"].as_array().unwrap().is_empty());
}

#[test]
fn lab_family_table_exposes_keys_and_panel_map() {
    let t = profile::lab_family_table();
    assert_eq!(t["recent_days"], profile::RECENT_DAYS);
    let cardio = t["families"]
        .as_array()
        .unwrap()
        .iter()
        .find(|f| f["key"] == "cardio")
        .unwrap();
    assert_eq!(cardio["label"], "心血管");
    assert!(cardio["keys"]
        .as_array()
        .unwrap()
        .iter()
        .any(|k| k == "inr"));
    assert_eq!(t["panel_family"]["肾功能"], "renal");
    assert_eq!(t["panel_family"]["血常规"], "common");
}

#[test]
fn undated_mentions_go_to_earlier_not_recent() {
    // 审查 I3:没有日期的提及说不出「180 天内」,进「更早」。
    let raw = [("", "处方\n阿司匹林 100mg qd\n".to_string())];
    let docs = common::mk_docs(&raw);
    let v = meds_json(&docs, "2026-10-22");
    assert!(row(&v["recent"], "阿司匹林").is_none());
    assert!(row(&v["earlier"], "阿司匹林").is_some());
}
