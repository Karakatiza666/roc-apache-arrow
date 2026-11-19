//! The checks of one valid case, and a shrinker that cuts a failing case
//! down to a short slice.

use arrow::array::{Array, ArrayRef};

use crate::{digest, identity, roc, validate, Feed};

/// Roc's `identity` gives back an array equal to the input (arrow-rs `==`,
/// which compares values and validity, not buffers), and valid under
/// `validate_full`.
pub fn check_identity(a: &ArrayRef, feed: Feed) -> Result<(), String> {
    let out = identity(a, feed).map_err(|e| format!("identity export: {e}"))?;
    if &out != a {
        return Err(format!("identity differs\n  input:  {a:?}\n  output: {out:?}"));
    }
    Ok(())
}

/// Roc's digest equals the digest of arrow-rs's reads, row by row.
pub fn check_digest(a: &ArrayRef, feed: Feed) -> Result<(), String> {
    let roc = digest(a, feed);
    let rust = crate::digest::digests(a);
    if roc.len() != rust.len() {
        return Err(format!("digest has {} rows, want {}", roc.len(), rust.len()));
    }
    for (i, (r, w)) in roc.iter().zip(&rust).enumerate() {
        if r != w {
            return Err(format!("digest row {i}\n  roc:      {r}\n  arrow-rs: {w}"));
        }
    }
    Ok(())
}

/// Roc accepts a valid array.
pub fn check_accept(a: &ArrayRef, feed: Feed) -> Result<(), String> {
    validate(a, feed).map_err(|e| format!("Roc refuses a valid array: {e}"))
}

/// One check under every feed. Roc must free every block it allocated.
pub fn check_feeds(a: &ArrayRef, check: fn(&ArrayRef, Feed) -> Result<(), String>) -> Result<(), String> {
    for feed in Feed::ALL {
        let before = roc::live_blocks();
        check(a, feed).map_err(|e| format!("{feed:?}: {e}"))?;
        let after = roc::live_blocks();
        if after != before {
            return Err(format!("{feed:?}: {} Roc blocks leak", after - before));
        }
    }
    if !roc::static_rc_intact() {
        return Err("Roc changed the static refcount word".into());
    }
    Ok(())
}

/// The shortest slice of `a` that still fails `fails`: halves first, then
/// one row less at either end.
pub fn shrink(a: &ArrayRef, fails: &dyn Fn(&ArrayRef) -> bool) -> ArrayRef {
    let mut best = a.clone();
    loop {
        let n = best.len();
        let mut candidates = vec![];
        if n >= 2 {
            candidates.push(best.slice(0, n / 2));
            candidates.push(best.slice(n / 2, n - n / 2));
        }
        if n >= 1 {
            candidates.push(best.slice(1, n - 1));
            candidates.push(best.slice(0, n - 1));
        }
        match candidates.into_iter().find(|c| fails(c)) {
            Some(smaller) => best = smaller,
            None => return best,
        }
    }
}

/// Run `check` on `a` under every feed; on a failure, shrink and describe.
pub fn run_case(label: &str, a: &ArrayRef, check: fn(&ArrayRef, Feed) -> Result<(), String>) -> Result<(), String> {
    roc::set_case(label);
    let Err(first) = check_feeds(a, check) else {
        return Ok(());
    };
    let small = shrink(a, &|c| check_feeds(c, check).is_err());
    let why = check_feeds(&small, check).err().unwrap_or(first);
    Err(format!(
        "{label}: type {}\n  shrunk to {} of {} rows: {small:?}\n  {why}",
        a.data_type(),
        small.len(),
        a.len()
    ))
}
