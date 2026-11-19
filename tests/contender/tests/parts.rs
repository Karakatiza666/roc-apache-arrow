//! The byte reads of `Utf8Column` and `BinaryColumn`, and the writer's
//! parts, against the same reads and writes done with arrow-rs, on random
//! text and binary columns of every byte layout. The `parts` entry point of
//! `app.roc` gives one Struct row per input row; see its table of fields.

use std::sync::Arc;

use arrow::array::*;
use arrow::datatypes::{DataType, Field, Fields};
use contender::check::run_case;
use contender::gen::{case_seed, Rng};
use contender::{base_seed, call, case_count, Feed};

/// Pieces of text: ASCII of both cases, every ASCII white space byte,
/// Unicode white space that the ASCII trim keeps, Latin, CJK and emoji.
/// The letters at the ends of each ASCII range, and the bytes just outside
/// them, test the case maps.
const PIECES: [&str; 28] = [
    "a", "z", "A", "Z", "q", "M", "@", "[", "`", "{", "0", "_", " ", " ", "\t", "\n", "\r", "\x0B", "\x0C", "\u{A0}",
    "\u{3000}", "é", "É", "ß", "日本", "한", "🎉", "👍🏽",
];

fn random_row(rng: &mut Rng, binary: bool) -> Vec<u8> {
    let n = match rng.below(10) {
        0 => 0,
        1..=7 => rng.below(12),
        _ => rng.below(40),
    };
    let mut out = vec![];
    for _ in 0..n {
        if binary && rng.chance(30) {
            out.push(rng.next_u64() as u8);
        } else {
            out.extend_from_slice(rng.pick(&PIECES).as_bytes());
        }
    }
    out
}

const TYPES: [DataType; 6] = [
    DataType::Utf8,
    DataType::LargeUtf8,
    DataType::Utf8View,
    DataType::Binary,
    DataType::LargeBinary,
    DataType::BinaryView,
];

fn is_text(dt: &DataType) -> bool {
    matches!(dt, DataType::Utf8 | DataType::LargeUtf8 | DataType::Utf8View)
}

/// An array of `dt` from rows; text rows must be UTF-8.
fn array_of(dt: &DataType, rows: Vec<Option<Vec<u8>>>) -> ArrayRef {
    let strs = || -> Vec<Option<String>> {
        rows.iter()
            .map(|r| r.as_ref().map(|b| String::from_utf8(b.clone()).expect("UTF-8 text")))
            .collect()
    };
    let bins: Vec<Option<&[u8]>> = rows.iter().map(|r| r.as_deref()).collect();
    match dt {
        DataType::Utf8 => Arc::new(StringArray::from(strs())),
        DataType::LargeUtf8 => Arc::new(LargeStringArray::from(strs())),
        DataType::Utf8View => Arc::new(StringViewArray::from(strs())),
        DataType::Binary => Arc::new(BinaryArray::from(bins)),
        DataType::LargeBinary => Arc::new(LargeBinaryArray::from(bins)),
        _ => Arc::new(BinaryViewArray::from(bins)),
    }
}

/// A random column of a random byte type, often cut from a longer one.
fn random_case(seed: u64) -> ArrayRef {
    let mut rng = Rng::new(seed);
    let dt = rng.pick(&TYPES).clone();
    let len = rng.below(30);
    let pre = if rng.chance(30) { rng.below(5) } else { 0 };
    let nulls = rng.below(3) * 15;
    let rows = (0..pre + len)
        .map(|_| (!rng.chance(nulls)).then(|| random_row(&mut rng, !is_text(&dt))))
        .collect();
    array_of(&dt, rows).slice(pre, len)
}

/// The bytes of row `i`, NULL or not.
fn row_bytes(a: &ArrayRef, i: usize) -> &[u8] {
    match a.data_type() {
        DataType::Utf8 => a.as_string::<i32>().value(i).as_bytes(),
        DataType::LargeUtf8 => a.as_string::<i64>().value(i).as_bytes(),
        DataType::Utf8View => a.as_string_view().value(i).as_bytes(),
        DataType::Binary => a.as_binary::<i32>().value(i),
        DataType::LargeBinary => a.as_binary::<i64>().value(i),
        _ => a.as_binary_view().value(i),
    }
}

fn is_space(b: u8) -> bool {
    b == b' ' || (9..=13).contains(&b)
}

fn trim(b: &[u8]) -> &[u8] {
    let start = b.iter().position(|&x| !is_space(x)).unwrap_or(b.len());
    let end = b.iter().rposition(|&x| !is_space(x)).map_or(start, |e| e + 1);
    &b[start..end]
}

fn output_type(dt: &DataType) -> DataType {
    let f = |name: &str, t: &DataType| Field::new(name, t.clone(), true);
    DataType::Struct(Fields::from(vec![
        f("same", dt),
        f("upper", dt),
        f("lower", dt),
        f("trim", dt),
        f("word", dt),
        f("mixed", dt),
        f("mixed_len", &DataType::Int64),
        f("len", &DataType::Int64),
        f("first", &DataType::Int32),
        f("last", &DataType::Int32),
        f("past", &DataType::Int32),
        f("space", &DataType::Int64),
        f("space_in_trim", &DataType::Int64),
        f("eq_prev", &DataType::Boolean),
        f("eq_prev_str", &DataType::Boolean),
    ]))
}

/// The output of `parts`, computed with arrow-rs.
fn expected(a: &ArrayRef) -> ArrayRef {
    let dt = a.data_type();
    let n = a.len();
    let rows: Vec<&[u8]> = (0..n).map(|i| row_bytes(a, i)).collect();
    let text = |f: &dyn Fn(&[u8]) -> Vec<u8>| array_of(dt, (0..n).map(|i| a.is_valid(i).then(|| f(rows[i]))).collect());
    let mixed = |b: &[u8]| [b"<|".as_slice(), b, "é>".as_bytes()].concat();
    let byte = |b: Option<&u8>| b.map_or(-1, |&x| x as i32);
    let prev = |i: usize| if i == 0 { &[][..] } else { rows[i - 1] };
    let columns: Vec<ArrayRef> = vec![
        text(&|b| b.to_vec()),
        text(&|b| b.to_ascii_uppercase()),
        text(&|b| b.to_ascii_lowercase()),
        text(&|b| trim(b).to_vec()),
        text(&|b| {
            let t = trim(b);
            t[..t.iter().position(|&x| is_space(x)).unwrap_or(t.len())].to_vec()
        }),
        text(&mixed),
        Arc::new(Int64Array::from_iter_values(rows.iter().map(|b| mixed(b).len() as i64))),
        Arc::new(Int64Array::from_iter_values(rows.iter().map(|b| b.len() as i64))),
        Arc::new(Int32Array::from_iter_values(rows.iter().map(|b| byte(b.first())))),
        Arc::new(Int32Array::from_iter_values(rows.iter().map(|b| byte(b.last())))),
        Arc::new(Int32Array::from_iter_values(rows.iter().map(|_| -1))),
        Arc::new(Int64Array::from_iter_values(
            rows.iter()
                .map(|b| b.iter().position(|&x| x == b' ').map_or(-1, |k| k as i64)),
        )),
        Arc::new(Int64Array::from_iter_values(rows.iter().map(|b| {
            let start = b.iter().position(|&x| !is_space(x)).unwrap_or(b.len());
            let t = trim(b);
            t.iter().position(|&x| x == b' ').map_or(-1, |k| (start + k) as i64)
        }))),
        Arc::new(BooleanArray::from_iter((0..n).map(|i| Some(rows[i] == prev(i))))),
        Arc::new(BooleanArray::from_iter(
            (0..n).map(|i| Some(rows[i] == String::from_utf8_lossy(prev(i)).as_bytes())),
        )),
    ];
    let DataType::Struct(fields) = output_type(dt) else {
        unreachable!()
    };
    Arc::new(StructArray::new(fields, columns, None))
}

/// `parts` and `parts_bin` give what arrow-rs gives.
fn check_parts(a: &ArrayRef, feed: Feed) -> Result<(), String> {
    let want = expected(a);
    for entry in ["parts", "parts_bin"] {
        let got = call(entry, a.as_ref(), feed, &output_type(a.data_type())).map_err(|e| format!("{entry}: {e}"))?;
        if got.as_ref() != want.as_ref() {
            let (g, w) = (got.as_struct(), want.as_struct());
            let field = (0..w.num_columns())
                .find(|&k| g.column(k) != w.column(k))
                .map_or("?".to_string(), |k| {
                    format!(
                        "{}: got {:?}, want {:?}",
                        w.fields()[k].name(),
                        g.column(k),
                        w.column(k)
                    )
                });
            return Err(format!("{entry} differs in {field}"));
        }
    }
    Ok(())
}

#[test]
fn parts_and_byte_reads_equal_arrow_rs() {
    let base = base_seed();
    let n = case_count(300);
    let mut failures = vec![];
    for i in 0..n {
        let seed = case_seed(base, i);
        let a = random_case(seed);
        let label = format!("parts case {i} (CONTENDER_SEED={base}, case seed {seed})");
        if let Err(e) = run_case(&label, &a, check_parts) {
            failures.push(e);
        }
    }
    eprintln!("parts: {n} random cases, base seed {base}, {} failures", failures.len());
    assert!(
        failures.is_empty(),
        "{}",
        failures.iter().take(5).cloned().collect::<Vec<_>>().join("\n\n")
    );
}

/// Every byte type at 0, 1 and 37 rows, each row of one piece, so each
/// piece meets each read on its own.
#[test]
fn every_piece_in_every_type() {
    let mut failures = vec![];
    for dt in TYPES {
        let rows: Vec<Option<Vec<u8>>> = PIECES
            .iter()
            .map(|p| Some(p.as_bytes().to_vec()))
            .chain([None, Some(vec![]), Some(b"  two words  ".to_vec())])
            .collect();
        let all = array_of(&dt, rows);
        for len in [0, 1, 37.min(all.len())] {
            let a = all.slice(0, len);
            if let Err(e) = run_case(&format!("{dt} {len} rows"), &a, check_parts) {
                failures.push(e);
            }
        }
    }
    assert!(failures.is_empty(), "{}", failures.join("\n\n"));
}
