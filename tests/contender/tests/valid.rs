//! The valid corpus: random arrays over the type matrix, and every leaf type
//! under every NULL mode, length and offset. Each case runs under every feed
//! (typed lists, bytes only, trusted text).

use std::sync::Arc;

use arrow::array::*;
use arrow::datatypes::{DataType, Field};
use contender::check::{check_accept, check_digest, check_identity, run_case};
use contender::gen::{case_seed, leaf_types, random_array, random_case, Nulls, Rng};
use contender::{base_seed, case_count, Feed};

type Check = fn(&ArrayRef, Feed) -> Result<(), String>;

/// Run `check` on the random cases; report every failure, then fail.
fn random_corpus(name: &str, check: Check) {
    let base = base_seed();
    let n = case_count(300);
    let mut failures = vec![];
    for i in 0..n {
        let seed = case_seed(base, i);
        let a = random_case(seed);
        if let Err(e) = run_case(
            &format!("{name} case {i} (CONTENDER_SEED={base}, case seed {seed})"),
            &a,
            check,
        ) {
            failures.push(e);
        }
    }
    eprintln!(
        "{name}: {n} random cases, base seed {base}, {} failures",
        failures.len()
    );
    assert!(
        failures.is_empty(),
        "{}",
        failures.iter().take(5).cloned().collect::<Vec<_>>().join("\n\n")
    );
}

#[test]
fn identity_equals_input() {
    random_corpus("identity", check_identity);
}

#[test]
fn digest_equals_arrow_rs_reads() {
    random_corpus("digest", check_digest);
}

#[test]
fn validate_accepts_valid_arrays() {
    random_corpus("validate", check_accept);
}

/// Every leaf type, and each nested type over it, with no, some and all
/// NULLs, at 0, 1 and 37 rows, cut from a longer array or not.
fn matrix() -> Vec<(String, ArrayRef)> {
    let mut rng = Rng::new(7);
    let mut out = vec![];
    let nested = |t: &DataType| -> Vec<DataType> {
        let f = Arc::new(Field::new("item", t.clone(), true));
        vec![
            t.clone(),
            DataType::List(f.clone()),
            DataType::LargeList(f.clone()),
            DataType::FixedSizeList(f.clone(), 2),
            DataType::Struct(vec![Field::new("a", t.clone(), true), Field::new("b", DataType::Int32, true)].into()),
        ]
    };
    for leaf in leaf_types() {
        for dt in nested(&leaf) {
            for nulls in [Nulls::None, Nulls::Some, Nulls::All] {
                for len in [0, 1, 37] {
                    let a = random_array(&mut rng, &dt, len, nulls);
                    out.push((format!("{dt} {nulls:?} {len} rows"), a));
                }
            }
        }
    }
    out
}

#[test]
fn matrix_identity_digest_validate() {
    let mut failures = vec![];
    let cases = matrix();
    for (label, a) in &cases {
        for (what, check) in [
            ("identity", check_identity as Check),
            ("digest", check_digest),
            ("validate", check_accept),
        ] {
            if let Err(e) = run_case(&format!("{what} {label}"), a, check) {
                failures.push(e);
            }
        }
    }
    eprintln!("matrix: {} arrays, {} failures", cases.len(), failures.len());
    assert!(
        failures.is_empty(),
        "{}",
        failures.iter().take(5).cloned().collect::<Vec<_>>().join("\n\n")
    );
}
