//! 英文过敏写法(Epic 样式;2026-10-23 底部四 tab spec §5.2)。中文层的行为由
//! `corpus_summary.rs` 与手机端测试守着,这里只管英文两种结构化写法与四种否定。

const TABLE: &str = "History\n\nAllergies\nAllergen                      Reactions\n • Penicillin                 Rash\n • Seasonal Ic [Octacosanol]  \n\nHome Medications:\n • Metoprolol 25 mg\n";

#[test]
fn table_form_yields_substance_and_reaction_verbatim() {
    let v = parser::extract_allergies_pairs(TABLE);
    assert_eq!(
        v,
        vec![
            ("Penicillin".to_string(), "Rash".to_string()),
            ("Seasonal Ic [Octacosanol]".to_string(), String::new()),
        ]
    );
}

#[test]
fn table_form_with_colon_header_and_middle_dot() {
    let t = "Allergies:\nAllergies\nAllergen   Reactions\n · Shellfish Allergy   Itching\n\nPatient's Medications\n";
    assert_eq!(
        parser::extract_allergies_pairs(t),
        vec![("Shellfish Allergy".to_string(), "Itching".to_string())]
    );
}

#[test]
fn inline_form_splits_on_commas() {
    let v =
        parser::extract_allergies_pairs("          Allergies: Penicillin, Sulfa drugs, Latex\n");
    assert_eq!(
        v,
        vec![
            ("Penicillin".to_string(), String::new()),
            ("Sulfa drugs".to_string(), String::new()),
            ("Latex".to_string(), String::new()),
        ]
    );
}

#[test]
fn negations_yield_nothing() {
    for t in [
        "Allergies: No Known Allergies\n",
        "Allergies: NKDA\n",
        "Allergies: nka\n",
        "Allergies\nAllergen  Reactions\n • No Known Allergies\n",
        "Allergies: Patient has no known allergies\n",
        "Allergies: No known drug allergies\n",
    ] {
        assert!(parser::extract_allergies_pairs(t).is_empty(), "{t:?}");
    }
}

#[test]
fn table_stops_at_blank_line_or_next_heading() {
    // 表后的「Home Medications:」及其条目不是过敏。
    let v = parser::extract_allergies_pairs(TABLE);
    assert!(v.iter().all(|(s, _)| !s.contains("Metoprolol")), "{v:?}");
    // 没有空行、直接接下一个以冒号结尾的标题:同样停。
    let t =
        "Allergies\nAllergen  Reactions\n • Latex  Hives\nHome Medications:\n • Aspirin 81 mg\n";
    assert_eq!(parser::extract_allergies_pairs(t).len(), 1);
}

#[test]
fn chinese_and_english_layers_coexist() {
    let t = "过敏史:青霉素(皮疹)\nAllergies: Latex\n";
    assert_eq!(
        parser::extract_allergies_pairs(t),
        vec![
            ("青霉素".to_string(), "皮疹".to_string()),
            ("Latex".to_string(), String::new()),
        ]
    );
}
