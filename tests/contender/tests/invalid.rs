//! The invalid corpus: valid arrays broken at the buffer level. Roc's
//! accept or refuse (`from_host` and the views) must match arrow-rs's
//! `validate_full`, except for the intended differences of `intended`.

use std::collections::BTreeMap;
use std::panic::{catch_unwind, AssertUnwindSafe};

use contender::gen::{case_seed, random_case, Rng};
use contender::mutate::{mutate, Kind, KINDS};
use contender::{base_seed, case_count, roc, validate_data, Feed};

/// Where Roc accepts what arrow-rs refuses, by design. The README lists
/// each one.
fn intended(kind: Kind, feed: Feed) -> Option<&'static str> {
    match kind {
        Kind::NullCountLie => Some("Roc trusts null_count"),
        Kind::NonNullableNulls => Some("Roc does not check the nullability of a field"),
        Kind::SplitCodePoint if feed.trusted_text => Some("Roc does not check trusted text"),
        _ => None,
    }
}

/// The feeds a mutant runs under. Text that is not UTF-8 never goes in as
/// a trusted Str: that breaks the host's promise, not Roc.
fn feeds(kind: Kind) -> Vec<Feed> {
    match kind {
        Kind::BadUtf8 => vec![Feed::TYPED, Feed::BYTES],
        _ => Feed::ALL.to_vec(),
    }
}

#[derive(Default, Debug)]
struct Tally {
    both_refuse: u64,
    both_accept: u64,
    intended: u64,
    disagree: u64,
}

#[test]
fn roc_agrees_with_validate_full() {
    let base = base_seed();
    let n = case_count(300) * 2;
    let mut tally: BTreeMap<Kind, Tally> = BTreeMap::new();
    let mut failures = vec![];
    for i in 0..n {
        let seed = case_seed(base, i);
        let data = random_case(seed).to_data();
        let mut rng = Rng::new(seed ^ 0x1D);
        for kind in KINDS {
            let Some(m) = mutate(&mut rng, kind, &data) else {
                continue;
            };
            let arrow = match catch_unwind(AssertUnwindSafe(|| m.data.validate_full())) {
                Ok(Ok(())) => Ok(()),
                Ok(Err(e)) => Err(e.to_string()),
                Err(_) => Err("arrow-rs panicked".to_string()),
            };
            for feed in feeds(kind) {
                let label = format!(
                    "case {i} (CONTENDER_SEED={base}) {kind:?} at {:?} {feed:?}, type {}",
                    m.path,
                    data.data_type()
                );
                roc::set_case(&label);
                let before = roc::live_blocks();
                let roc_verdict = validate_data(&m.data, feed, None);
                assert_eq!(roc::live_blocks(), before, "{label}: Roc blocks leak");
                let t = tally.entry(kind).or_default();
                match (&arrow, &roc_verdict) {
                    (Err(_), Err(_)) => t.both_refuse += 1,
                    (Ok(()), Ok(())) => t.both_accept += 1,
                    (Err(_), Ok(())) if intended(kind, feed).is_some() => t.intended += 1,
                    _ => {
                        t.disagree += 1;
                        failures.push(format!("{label}\n  arrow-rs: {arrow:?}\n  roc:      {roc_verdict:?}"));
                    }
                }
            }
        }
    }
    eprintln!(
        "{:<18} {:>11} {:>11} {:>9} {:>9}",
        "kind", "both refuse", "both accept", "intended", "disagree"
    );
    for (kind, t) in &tally {
        eprintln!(
            "{:<18} {:>11} {:>11} {:>9} {:>9}",
            format!("{kind:?}"),
            t.both_refuse,
            t.both_accept,
            t.intended,
            t.disagree
        );
    }
    assert!(
        failures.is_empty(),
        "{} disagreements:\n{}",
        failures.len(),
        failures.iter().take(8).cloned().collect::<Vec<_>>().join("\n")
    );
}
