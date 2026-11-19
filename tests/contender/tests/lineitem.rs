//! The lineitem job: Roc, with checked and trusted text and in both styles,
//! and the arrow-rs kernels give the output of the arrow-rs row loop on
//! every batch.

use std::sync::Arc;

use arrow::array::{Array, ArrayRef, StringArray, StructArray};
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

/// Comments that the bench data does not hold: Unicode white space at the
/// ends (which `trim` removes and an ASCII trim keeps), every ASCII white
/// space byte, no space, and only spaces.
#[test]
fn lineitem_comments_at_the_edges_agree() {
    const EDGES: [&str; 12] = [
        "\u{A0}word rest\u{A0}",
        "\u{3000}東京 x\u{3000}",
        "\u{2007}a b\u{2028}",
        "\u{85}x y\u{1680}",
        " \t\n\x0B\x0C\rmixed ws \r\n",
        "oneword",
        "   ",
        "",
        "°deg tail°",
        "tail✅",
        "✅ head",
        "a\u{A0}b c",
    ];
    let t = table(600, 7);
    let comments: ArrayRef = Arc::new(StringArray::from_iter(
        (0..t.len()).map(|i| (i % 13 != 12).then(|| EDGES[i % 13 % EDGES.len()])),
    ));
    let (fields, mut columns, nulls) = t.into_parts();
    let k = fields
        .iter()
        .position(|f| f.name() == "comment")
        .expect("a comment column");
    columns[k] = comments;
    let t = StructArray::new(fields, columns, nulls);
    for way in Way::ALL {
        check_way(way, &batches(&t, 64)).unwrap();
    }
}
