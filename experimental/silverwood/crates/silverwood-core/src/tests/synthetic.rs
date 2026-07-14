//! A self-contained two-version toy schema that exercises the migration +
//! convergence machinery across a genuine version bump (the real schema has only
//! one version today). It models the committed **barrier + additive-safe**
//! guarantee with a *destructive* migration:
//!
//!   v1: root `toy` = { schema_version:1, items: Map<str,str> }
//!   v2: root `toy` = { schema_version:2, note: str, data: { items: Map } }
//!
//! v1→v2 moves `items` under a new `data` container (destructive) and adds
//! `note` (additive, default ""). The property: after a phase of concurrent v1
//! edits (gossiped in any order), a barrier migration (rebuild, distributed to
//! all), and a phase of concurrent v2 edits (any order), every forest converges
//! and no item is lost across the whole lifecycle.

use std::collections::{BTreeMap, BTreeSet};

use loro::{Container, ExportMode, LoroDoc, LoroMap, ValueOrContainer};
use proptest::prelude::*;

const TOY: &str = "toy";

/// The toy's logical content — the ground truth for convergence and no-loss.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct Toy {
    items: BTreeMap<String, String>,
    note: String,
}

fn build_v1(peer: u64, items: &BTreeMap<String, String>) -> LoroDoc {
    let d = LoroDoc::new();
    d.set_peer_id(peer).unwrap();
    let root = d.get_map(TOY);
    root.insert("schema_version", 1i64).unwrap();
    let m = root.insert_container("items", LoroMap::new()).unwrap();
    for (k, v) in items {
        m.insert(k.as_str(), v.as_str()).unwrap();
    }
    d.commit();
    d
}

fn build_v2(peer: u64, toy: &Toy) -> LoroDoc {
    let d = LoroDoc::new();
    d.set_peer_id(peer).unwrap();
    let root = d.get_map(TOY);
    root.insert("schema_version", 2i64).unwrap();
    root.insert("note", toy.note.as_str()).unwrap();
    let data = root.insert_container("data", LoroMap::new()).unwrap();
    let m = data.insert_container("items", LoroMap::new()).unwrap();
    for (k, v) in &toy.items {
        m.insert(k.as_str(), v.as_str()).unwrap();
    }
    d.commit();
    d
}

fn json_map(v: Option<&serde_json::Value>) -> BTreeMap<String, String> {
    v.and_then(|v| v.as_object())
        .map(|o| {
            o.iter()
                .filter_map(|(k, val)| val.as_str().map(|s| (k.clone(), s.to_string())))
                .collect()
        })
        .unwrap_or_default()
}

/// Decode a toy document at whatever version it declares into the model.
fn model(doc: &LoroDoc) -> Toy {
    let root = serde_json::to_value(doc.get_map(TOY).get_deep_value()).unwrap();
    let version = root
        .get("schema_version")
        .and_then(|v| v.as_u64())
        .unwrap_or(1);
    match version {
        1 => Toy {
            items: json_map(root.get("items")),
            note: String::new(),
        },
        2 => Toy {
            items: json_map(root.get("data").and_then(|d| d.get("items"))),
            note: root
                .get("note")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
        },
        v => panic!("unknown toy version {v}"),
    }
}

/// Migrate any-version toy bytes to the latest (rebuild). Deterministic in its
/// *logical* result: same input model → same output model.
fn migrate_to_latest(bytes: &[u8], peer: u64) -> Vec<u8> {
    let d = LoroDoc::new();
    d.import(bytes).unwrap();
    build_v2(peer, &model(&d))
        .export(ExportMode::snapshot())
        .unwrap()
}

fn child_map(parent: &LoroMap, key: &str) -> LoroMap {
    match parent.get(key) {
        Some(ValueOrContainer::Container(Container::Map(m))) => m,
        _ => panic!("expected map at {key}"),
    }
}

/// Add an item to a v2 doc in place (into the genesis `data.items` container).
fn v2_add_item(doc: &LoroDoc, key: &str, val: &str) {
    let data = child_map(&doc.get_map(TOY), "data");
    child_map(&data, "items").insert(key, val).unwrap();
    doc.commit();
}

fn import_as(bytes: &[u8], peer: u64) -> LoroDoc {
    let d = LoroDoc::new();
    d.import(bytes).unwrap();
    d.set_peer_id(peer).unwrap();
    d
}

/// Merge every ordered (src → tgt) update once, in `order`'s order.
fn gossip(forests: &[LoroDoc], order: &[u64]) {
    let blobs: Vec<Vec<u8>> = forests
        .iter()
        .map(|d| d.export(ExportMode::all_updates()).unwrap())
        .collect();
    let mut steps: Vec<(usize, usize)> = Vec::new();
    for src in 0..forests.len() {
        for tgt in 0..forests.len() {
            if src != tgt {
                steps.push((tgt, src));
            }
        }
    }
    let mut keyed: Vec<(u64, (usize, usize))> = steps
        .iter()
        .enumerate()
        .map(|(idx, s)| (order[idx % order.len()], *s))
        .collect();
    keyed.sort_by_key(|(key, _)| *key);
    for (_, (tgt, src)) in keyed {
        forests[tgt].import(&blobs[src]).unwrap();
    }
}

/// `(forest count, phase-A item ids per forest, phase-B item ids per forest,
/// phase-A gossip order, phase-B gossip order)`.
type Scenario = (usize, Vec<Vec<u8>>, Vec<Vec<u8>>, Vec<u64>, Vec<u64>);

fn scenario() -> impl Strategy<Value = Scenario> {
    (2usize..=4).prop_flat_map(|k| {
        (
            Just(k),
            prop::collection::vec(prop::collection::vec(0u8..5, 0..4), k),
            prop::collection::vec(prop::collection::vec(0u8..5, 0..4), k),
            prop::collection::vec(any::<u64>(), 24),
            prop::collection::vec(any::<u64>(), 24),
        )
    })
}

proptest! {
    #![proptest_config(ProptestConfig::with_cases(48))]

    #[test]
    fn toy_migration_converges_under_barrier((k, pa, pb, oa, ob) in scenario()) {
        // Base document at v1.
        let mut base_items = BTreeMap::new();
        base_items.insert("base".to_string(), "0".to_string());
        let base = build_v1(1, &base_items)
            .export(ExportMode::snapshot())
            .unwrap();

        // --- Phase A (v1): disjoint concurrent adds, gossiped in any order. ---
        let forests: Vec<LoroDoc> = (0..k)
            .map(|i| {
                let d = import_as(&base, 10 * (i as u64 + 1));
                for j in pa[i].iter().copied().collect::<BTreeSet<u8>>() {
                    child_map(&d.get_map(TOY), "items")
                        .insert(&format!("a{i}-{j}"), "1")
                        .unwrap();
                }
                d.commit();
                d
            })
            .collect();
        gossip(&forests, &oa);

        let a_models: Vec<Toy> = forests.iter().map(model).collect();
        for m in &a_models[1..] {
            prop_assert_eq!(&a_models[0], m);
        }
        let union_a = a_models[0].items.clone();

        // --- Barrier: one forest migrates; the migrated bytes are adopted by all. ---
        let migrated =
            migrate_to_latest(&forests[0].export(ExportMode::snapshot()).unwrap(), 999);
        let mdoc = {
            let d = LoroDoc::new();
            d.import(&migrated).unwrap();
            d
        };
        // Migration preserves every item (no loss) and defaults the new field.
        prop_assert_eq!(model(&mdoc).items, union_a.clone());
        prop_assert_eq!(model(&mdoc).note, String::new());
        // Migration is idempotent at the logical level.
        let again = migrate_to_latest(&migrated, 998);
        let adoc = {
            let d = LoroDoc::new();
            d.import(&again).unwrap();
            d
        };
        prop_assert_eq!(model(&adoc), model(&mdoc));

        // --- Phase B (v2): adopt the migrated base, disjoint adds, gossip any order. ---
        let v2forests: Vec<LoroDoc> = (0..k)
            .map(|i| {
                let d = import_as(&migrated, 20 * (i as u64 + 1));
                for j in pb[i].iter().copied().collect::<BTreeSet<u8>>() {
                    v2_add_item(&d, &format!("b{i}-{j}"), "1");
                }
                d
            })
            .collect();
        gossip(&v2forests, &ob);

        let b_models: Vec<Toy> = v2forests.iter().map(model).collect();
        for m in &b_models[1..] {
            prop_assert_eq!(&b_models[0], m);
        }

        // No loss across the whole lifecycle: union of phase A + phase B items.
        let mut expected = union_a;
        for (i, adds) in pb.iter().enumerate() {
            for j in adds.iter().copied().collect::<BTreeSet<u8>>() {
                expected.insert(format!("b{i}-{j}"), "1".to_string());
            }
        }
        prop_assert_eq!(b_models[0].items.clone(), expected);
    }
}
