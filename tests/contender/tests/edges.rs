//! Edges of the C Data Interface that random arrays do not reach.

use arrow::array::*;
use arrow::datatypes::DataType;
use contender::check::check_digest;
use contender::export::from_c_parts;
use contender::gen::{leaf_types, random_array, Nulls, Rng};
use contender::import::{roles, Role};
use contender::roc::{static_list, HostBuffer};
use contender::{digest, Feed, HostInput};

/// `null_count` -1 means "not known": Roc then reads the bitmap, and the
/// digest is the one of the known count.
#[test]
fn unknown_null_count_reads_the_bitmap() {
    let mut rng = Rng::new(11);
    for dt in leaf_types() {
        if dt == DataType::Null {
            continue;
        }
        let a = random_array(&mut rng, &dt, 19, Nulls::Some);
        assert!(a.null_count() > 0, "{dt}: the case has NULLs");
        for feed in Feed::ALL {
            check_digest(&a, feed).unwrap();
            let mut input = HostInput::from_array("digest", &a, feed);
            input.array.null_count = -1;
            let rows = input.run().into_strings();
            assert_eq!(rows, digest(&a, feed), "{dt} {feed:?}");
        }
    }
}

/// A C producer may pass NULL for a buffer of no bytes. Roc takes an array
/// of no rows whose every buffer is NULL. arrow-rs's `from_ffi` takes it
/// too, except a NULL offsets buffer (an intended difference: Roc reads it
/// as the empty offsets buffer that arrow-rs takes for no rows).
#[test]
fn no_rows_with_null_buffers() {
    let mut rng = Rng::new(12);
    for dt in leaf_types() {
        let a = random_array(&mut rng, &dt, 0, Nulls::None);
        let rs = roles(
            &dt,
            if matches!(dt, DataType::Utf8View | DataType::BinaryView) {
                3
            } else {
                0
            },
        );
        let has_offsets = rs.iter().any(|r| matches!(r, Role::Offsets(_)));
        let arrow = unsafe { from_c_parts(&dt, 0, 0, vec![std::ptr::null(); rs.len()]) };
        assert_eq!(arrow.is_ok(), !has_offsets, "{dt}: arrow-rs gives {arrow:?}");

        let absent = vec![HostBuffer::absent(); rs.len()];
        let mut input = HostInput::from_array("validate", &a, Feed::TYPED);
        input.array.buffers = static_list(absent.as_ptr(), absent.len());
        let verdict = input.run().into_strings();
        assert_eq!(verdict, vec!["accept".to_string()], "{dt}: Roc refuses");
    }
}
