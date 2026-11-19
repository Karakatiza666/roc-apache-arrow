//! The lineitem job: Roc, with checked and trusted text, and the arrow-rs
//! kernels give the output of the arrow-rs row loop on every batch.

use contender::lineitem::{batches, check_way, table, Way};

#[test]
fn lineitem_ways_agree() {
    let t = table(20_000, 0x11E1_7E00);
    // A batch size that leaves a short last batch, and one of a few rows.
    for size in [8192, 7] {
        let bs = batches(&t, size);
        let bs = if size == 7 { &bs[..40] } else { &bs[..] };
        for way in Way::ALL {
            check_way(way, bs).unwrap();
        }
    }
}
