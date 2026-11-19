//! A realistic load for the bench and the differential test: a table modeled
//! on the TPC-H `lineitem` table, cut into record batches, and one batch job
//! written three ways that give the same output.
//!
//! | Way | Code |
//! |-----|------|
//! | [`Way::RustRows`] | arrow-rs arrays read row by row, output through builders |
//! | [`Way::RustKernels`] | arrow-rs compute kernels (filter, decimal arithmetic, length); the text and the groups in a loop, as arrow-rs has no kernel for them |
//! | [`Way::Roc`] | the `lineitem` entry point of `app.roc`: the package's views, byte reads and `Writer` parts, with no `Str` per row |
//! | [`Way::RocStr`] | the `lineitem_str` entry point: a `Str` per text read and per text written |
//!
//! The job, per batch: import through the C Data Interface; keep the rows
//! with `SHIP_FROM <= shipdate < SHIP_UNTIL`; compute
//! `disc_price = extendedprice * (1 - discount)` and
//! `charge = disc_price * (1 + tax)` as Decimal128; trim the comment and put
//! its first word in ASCII uppercase, with its byte length; total the rows
//! per (returnflag, linestatus); export the result through the C Data
//! Interface. A NULL operand makes a price NULL, and a sum skips it.

use std::sync::Arc;
use std::time::{Duration, Instant};

use arrow::array::*;
use arrow::buffer::OffsetBuffer;
use arrow::compute::kernels::boolean::and;
use arrow::compute::kernels::cmp::{gt_eq, lt};
use arrow::compute::kernels::length::length;
use arrow::compute::kernels::numeric::{add, mul, sub};
use arrow::compute::FilterBuilder;
use arrow::datatypes::*;
use arrow::ffi::{from_ffi, to_ffi};

use crate::gen::Rng;
use crate::{Feed, HostInput};

/// 1994-01-01 and 1997-03-01 as days since 1970-01-01: about half the rows.
pub const SHIP_FROM: i32 = 8766;
pub const SHIP_UNTIL: i32 = 9921;

/// The scale of every input decimal, and its precision.
const SCALE: i8 = 2;
const PRECISION: u8 = 15;

/// 1992-01-01, the first order date, and 1995-06-17, the "current date" that
/// sets returnflag and linestatus.
const FIRST_ORDER: i32 = 8035;
const ORDER_DAYS: i32 = 10440 - 151 - FIRST_ORDER;
const CURRENT: i32 = 9298;

const INSTRUCTS: [&str; 4] = ["DELIVER IN PERSON", "COLLECT COD", "NONE", "TAKE BACK RETURN"];
const MODES: [&str; 7] = ["REG AIR", "AIR", "RAIL", "SHIP", "TRUCK", "MAIL", "FOB"];

/// Words of the comments: ASCII as in TPC-H, and words of other scripts for
/// the rows of international text.
const WORDS: [&str; 30] = [
    "furiously",
    "carefully",
    "regular",
    "deposits",
    "packages",
    "ideas",
    "accounts",
    "final",
    "pending",
    "quickly",
    "slyly",
    "blithely",
    "ironic",
    "express",
    "bold",
    "special",
    "requests",
    "theodolites",
    "pinto",
    "beans",
    "foxes",
    "instructions",
    "dependencies",
    "excuses",
    "platelets",
    "asymptotes",
    "courts",
    "dolphins",
    "warthogs",
    "frets",
];
const WORLD_WORDS: [&str; 16] = [
    "café",
    "naïve",
    "Größe",
    "señor",
    "déjà",
    "über",
    "façade",
    "東京",
    "配送",
    "注文",
    "출고",
    "доставка",
    "📦",
    "🚚✅",
    "ünïcödé",
    "日本の港",
];

/// The table: 16 columns, about 5% NULL in discount, tax, receiptdate,
/// shipmode and comment.
pub fn schema() -> Fields {
    let dec = DataType::Decimal128(PRECISION, SCALE);
    Fields::from(vec![
        Field::new("orderkey", DataType::Int64, false),
        Field::new("partkey", DataType::Int64, false),
        Field::new("suppkey", DataType::Int64, false),
        Field::new("linenumber", DataType::Int32, false),
        Field::new("quantity", dec.clone(), false),
        Field::new("extendedprice", dec.clone(), false),
        Field::new("discount", dec.clone(), true),
        Field::new("tax", dec, true),
        Field::new("returnflag", DataType::Utf8, false),
        Field::new("linestatus", DataType::Utf8, false),
        Field::new("shipdate", DataType::Date32, false),
        Field::new("commitdate", DataType::Date32, false),
        Field::new("receiptdate", DataType::Date32, true),
        Field::new("shipinstruct", DataType::Utf8, false),
        Field::new("shipmode", DataType::Utf8, true),
        Field::new("comment", DataType::Utf8, true),
    ])
}

/// A comment of 10 to 44 characters; with `world`, some words are not ASCII.
/// One in ten has spaces before or after it.
fn comment(rng: &mut Rng, world: bool) -> String {
    let want = 10 + rng.below(35);
    let mut out = String::new();
    let mut chars = 0;
    loop {
        let word = if world && (chars == 0 || rng.chance(35)) && rng.chance(60) {
            *rng.pick(&WORLD_WORDS)
        } else {
            *rng.pick(&WORDS)
        };
        let n = word.chars().count();
        let gap = usize::from(chars > 0);
        if chars + gap + n > want {
            break;
        }
        if gap == 1 {
            out.push(' ');
        }
        out.push_str(word);
        chars += gap + n;
    }
    if out.is_empty() {
        out.push_str(&rng.pick(&WORDS)[..1]);
    }
    if world && out.is_ascii() {
        out.push(' ');
        out.push_str(rng.pick(&WORLD_WORDS[..7]));
    }
    if rng.chance(10) {
        out = format!("{}{}{}", " ".repeat(rng.below(3)), out, " ".repeat(1 + rng.below(2)));
    }
    out
}

/// `rows` rows from `seed`: orders of 1 to 7 lines, each line of the order
/// shipped 1 to 121 days after the order date.
pub fn table(rows: usize, seed: u64) -> StructArray {
    let mut rng = Rng::new(seed);
    let dec = || Decimal128Builder::with_capacity(rows).with_data_type(DataType::Decimal128(PRECISION, SCALE));
    let mut orderkey = Int64Builder::with_capacity(rows);
    let mut partkey = Int64Builder::with_capacity(rows);
    let mut suppkey = Int64Builder::with_capacity(rows);
    let mut linenumber = Int32Builder::with_capacity(rows);
    let (mut quantity, mut price, mut discount, mut tax) = (dec(), dec(), dec(), dec());
    let mut flag = StringBuilder::with_capacity(rows, rows);
    let mut status = StringBuilder::with_capacity(rows, rows);
    let mut ship = Date32Builder::with_capacity(rows);
    let mut commit = Date32Builder::with_capacity(rows);
    let mut receipt = Date32Builder::with_capacity(rows);
    let mut instruct = StringBuilder::with_capacity(rows, rows * 12);
    let mut mode = StringBuilder::with_capacity(rows, rows * 5);
    let mut text = StringBuilder::with_capacity(rows, rows * 32);
    let (mut order, mut line, mut lines, mut order_date) = (0i64, 0i32, 0i32, 0i32);
    for _ in 0..rows {
        if line == lines {
            order += 1;
            line = 0;
            lines = 1 + rng.below(7) as i32;
            order_date = FIRST_ORDER + rng.below(ORDER_DAYS as usize) as i32;
        }
        line += 1;
        // TPC-H keys are sparse: 8 of each 32.
        orderkey.append_value((order / 8) * 32 + order % 8 + 1);
        let part = 1 + rng.below(200_000) as i64;
        partkey.append_value(part);
        suppkey.append_value(1 + rng.below(10_000) as i64);
        linenumber.append_value(line);
        let qty = 1 + rng.below(50) as i128;
        let retail = (90_000 + (part / 10) % 20_001 + 100 * (part % 1_000)) as i128;
        quantity.append_value(qty * 100);
        price.append_value(qty * retail);
        discount.append_option((!rng.chance(5)).then(|| rng.below(11) as i128));
        tax.append_option((!rng.chance(5)).then(|| rng.below(9) as i128));
        let shipdate = order_date + 1 + rng.below(121) as i32;
        let receiptdate = shipdate + 1 + rng.below(30) as i32;
        ship.append_value(shipdate);
        commit.append_value(order_date + 30 + rng.below(61) as i32);
        receipt.append_option((!rng.chance(5)).then_some(receiptdate));
        flag.append_value(if receiptdate > CURRENT {
            "N"
        } else if rng.chance(50) {
            "R"
        } else {
            "A"
        });
        status.append_value(if shipdate > CURRENT { "O" } else { "F" });
        instruct.append_value(rng.pick(&INSTRUCTS));
        mode.append_option((!rng.chance(5)).then(|| *rng.pick(&MODES)));
        let world = rng.chance(30);
        let c = comment(&mut rng, world);
        text.append_option((!rng.chance(5)).then_some(c));
    }
    let columns: Vec<ArrayRef> = vec![
        Arc::new(orderkey.finish()),
        Arc::new(partkey.finish()),
        Arc::new(suppkey.finish()),
        Arc::new(linenumber.finish()),
        Arc::new(quantity.finish()),
        Arc::new(price.finish()),
        Arc::new(discount.finish()),
        Arc::new(tax.finish()),
        Arc::new(flag.finish()),
        Arc::new(status.finish()),
        Arc::new(ship.finish()),
        Arc::new(commit.finish()),
        Arc::new(receipt.finish()),
        Arc::new(instruct.finish()),
        Arc::new(mode.finish()),
        Arc::new(text.finish()),
    ];
    StructArray::new(schema(), columns, None)
}

/// The table in batches of `size` rows, each a copy at offset 0, as a
/// producer sends them.
pub fn batches(table: &StructArray, size: usize) -> Vec<StructArray> {
    let data = table.to_data();
    (0..table.len())
        .step_by(size)
        .map(|start| {
            let end = (start + size).min(table.len());
            let mut copy = MutableArrayData::new(vec![&data], false, end - start);
            copy.try_extend(0, start, end).expect("rows of the table");
            StructArray::from(copy.freeze())
        })
        .collect()
}

/// The bytes of every buffer of `data` and its children: what an import reads.
pub fn input_bytes(data: &ArrayData) -> usize {
    let own: usize = data.buffers().iter().map(|b| b.len()).sum();
    let nulls = data.nulls().map_or(0, |n| n.buffer().len());
    own + nulls + data.child_data().iter().map(input_bytes).sum::<usize>()
}

/// One Struct row of `rows`, the kept rows, and `groups`, the totals.
pub fn output_type() -> DataType {
    let rows = Fields::from(vec![
        Field::new("orderkey", DataType::Int64, true),
        Field::new("disc_price", DataType::Decimal128(38, 4), true),
        Field::new("charge", DataType::Decimal128(38, 6), true),
        Field::new("comment_norm", DataType::Utf8, true),
        Field::new("comment_len", DataType::Int32, true),
    ]);
    let groups = Fields::from(vec![
        Field::new("returnflag", DataType::Utf8, true),
        Field::new("linestatus", DataType::Utf8, true),
        Field::new("count", DataType::Int64, true),
        Field::new("sum_qty", DataType::Decimal128(38, 2), true),
        Field::new("sum_base_price", DataType::Decimal128(38, 2), true),
        Field::new("sum_disc_price", DataType::Decimal128(38, 4), true),
        Field::new("sum_charge", DataType::Decimal128(38, 6), true),
    ]);
    DataType::Struct(Fields::from(vec![
        Field::new_list("rows", Field::new("item", DataType::Struct(rows), true), true),
        Field::new_list("groups", Field::new("item", DataType::Struct(groups), true), true),
    ]))
}

/// The totals of one (returnflag, linestatus) group.
#[derive(Clone, Copy, Debug, Default)]
struct Totals {
    count: i64,
    qty: i128,
    base: i128,
    disc: i128,
    charge: i128,
}

const FLAGS: [&str; 3] = ["A", "N", "R"];
const STATUSES: [&str; 2] = ["F", "O"];

fn group_of(flag: &str, status: &str) -> usize {
    let f = FLAGS.iter().position(|x| *x == flag).expect("a known returnflag");
    let s = STATUSES.iter().position(|x| *x == status).expect("a known linestatus");
    f * 2 + s
}

/// The trimmed text with its first word in ASCII uppercase, into `out`.
fn normalize(text: &str, out: &mut String) {
    let trimmed = text.trim();
    match trimmed.split_once(' ') {
        Some((first, rest)) => {
            out.push_str(&first.to_ascii_uppercase());
            out.push(' ');
            out.push_str(rest);
        }
        None => out.push_str(&trimmed.to_ascii_uppercase()),
    }
}

fn column<'a>(t: &'a StructArray, name: &str) -> &'a ArrayRef {
    t.column_by_name(name).expect("a lineitem column")
}

fn decimal_type(scale: i8) -> DataType {
    DataType::Decimal128(38, scale)
}

fn decimals(xs: impl IntoIterator<Item = i128>, scale: i8) -> ArrayRef {
    Arc::new(Decimal128Array::from_iter_values(xs).with_data_type(decimal_type(scale)))
}

/// One Struct row of the two lists.
fn assemble(rows: Vec<ArrayRef>, totals: &[Totals; 6]) -> ArrayRef {
    let DataType::Struct(out) = output_type() else {
        unreachable!()
    };
    let item_fields = |i: usize| match out[i].data_type() {
        DataType::List(f) => f.clone(),
        _ => unreachable!(),
    };
    let rows_field = item_fields(0);
    let DataType::Struct(row_fields) = rows_field.data_type() else {
        unreachable!()
    };
    let rows = StructArray::new(row_fields.clone(), rows, None);
    let used: Vec<usize> = (0..6).filter(|g| totals[*g].count > 0).collect();
    let pick = |f: fn(&Totals) -> i128| used.iter().map(move |g| f(&totals[*g]));
    let groups_field = item_fields(1);
    let DataType::Struct(group_fields) = groups_field.data_type() else {
        unreachable!()
    };
    let groups = StructArray::new(
        group_fields.clone(),
        vec![
            Arc::new(StringArray::from_iter_values(used.iter().map(|g| FLAGS[g / 2]))),
            Arc::new(StringArray::from_iter_values(used.iter().map(|g| STATUSES[g % 2]))),
            Arc::new(Int64Array::from_iter_values(used.iter().map(|g| totals[*g].count))),
            decimals(pick(|t| t.qty), 2),
            decimals(pick(|t| t.base), 2),
            decimals(pick(|t| t.disc), 4),
            decimals(pick(|t| t.charge), 6),
        ],
        None,
    );
    let one = |field: FieldRef, child: StructArray| -> ArrayRef {
        let n = child.len();
        Arc::new(ListArray::new(
            field,
            OffsetBuffer::from_lengths([n]),
            Arc::new(child),
            None,
        ))
    };
    Arc::new(StructArray::new(
        out.clone(),
        vec![one(rows_field, rows), one(groups_field, groups)],
        None,
    ))
}

/// The job over arrow-rs arrays, row by row, as a typical arrow-rs user
/// writes it.
pub fn by_rows(t: &StructArray) -> ArrayRef {
    let (rows, totals) = row_loop(t, true);
    assemble(rows, &totals)
}

/// The row loop of [`by_rows`]: the output columns and the totals. Without
/// `text` it skips the comment, and its two text columns stay empty.
fn row_loop(t: &StructArray, text: bool) -> (Vec<ArrayRef>, [Totals; 6]) {
    let orderkey = column(t, "orderkey").as_primitive::<Int64Type>();
    let quantity = column(t, "quantity").as_primitive::<Decimal128Type>();
    let price = column(t, "extendedprice").as_primitive::<Decimal128Type>();
    let discount = column(t, "discount").as_primitive::<Decimal128Type>();
    let tax = column(t, "tax").as_primitive::<Decimal128Type>();
    let flag = column(t, "returnflag").as_string::<i32>();
    let status = column(t, "linestatus").as_string::<i32>();
    let shipdate = column(t, "shipdate").as_primitive::<Date32Type>();
    let comment = column(t, "comment").as_string::<i32>();
    let n = t.len();
    let mut keys = Int64Builder::with_capacity(n);
    let mut discs = Decimal128Builder::with_capacity(n).with_data_type(decimal_type(4));
    let mut charges = Decimal128Builder::with_capacity(n).with_data_type(decimal_type(6));
    let mut texts = StringBuilder::with_capacity(n, comment.value_data().len());
    let mut lens = Int32Builder::with_capacity(n);
    let mut totals = [Totals::default(); 6];
    let mut buf = String::new();
    for i in 0..n {
        if shipdate.is_null(i) {
            continue;
        }
        let day = shipdate.value(i);
        if !(SHIP_FROM..SHIP_UNTIL).contains(&day) {
            continue;
        }
        let base = price.value(i);
        let disc = discount.is_valid(i).then(|| base * (100 - discount.value(i)));
        let charge = disc.filter(|_| tax.is_valid(i)).map(|d| d * (100 + tax.value(i)));
        keys.append_value(orderkey.value(i));
        discs.append_option(disc);
        charges.append_option(charge);
        if !text {
            // The numeric phase: no comment work.
        } else if comment.is_valid(i) {
            buf.clear();
            normalize(comment.value(i), &mut buf);
            texts.append_value(&buf);
            lens.append_value(buf.len() as i32);
        } else {
            texts.append_null();
            lens.append_null();
        }
        let g = &mut totals[group_of(flag.value(i), status.value(i))];
        g.count += 1;
        g.qty += quantity.value(i);
        g.base += base;
        g.disc += disc.unwrap_or(0);
        g.charge += charge.unwrap_or(0);
    }
    let columns: Vec<ArrayRef> = vec![
        Arc::new(keys.finish()),
        Arc::new(discs.finish()),
        Arc::new(charges.finish()),
        Arc::new(texts.finish()),
        Arc::new(lens.finish()),
    ];
    (columns, totals)
}

/// The job with arrow-rs compute kernels where arrow-rs has them: the date
/// filter, the decimal arithmetic and the byte length. The comment and the
/// groups take a loop, since arrow-rs has no kernel for either.
pub fn by_kernels(t: &StructArray) -> ArrayRef {
    let shipdate = column(t, "shipdate");
    let from = Date32Array::new_scalar(SHIP_FROM);
    let until = Date32Array::new_scalar(SHIP_UNTIL);
    let mask = and(&gt_eq(shipdate, &from).unwrap(), &lt(shipdate, &until).unwrap()).unwrap();
    let keep = FilterBuilder::new(&mask).optimize().build();
    let pick = |name: &str| keep.filter(column(t, name).as_ref()).unwrap();
    let orderkey = pick("orderkey");
    let quantity = pick("quantity");
    let price = pick("extendedprice");
    let one = Scalar::new(
        Decimal128Array::from(vec![100])
            .with_precision_and_scale(PRECISION, SCALE)
            .unwrap(),
    );
    let disc = mul(&price, &sub(&one, &pick("discount")).unwrap()).unwrap();
    let charge = mul(&disc, &add(&one, &pick("tax")).unwrap()).unwrap();
    let disc = disc
        .as_primitive::<Decimal128Type>()
        .clone()
        .with_data_type(decimal_type(4));
    let charge = charge
        .as_primitive::<Decimal128Type>()
        .clone()
        .with_data_type(decimal_type(6));

    let comment = pick("comment");
    let comment = comment.as_string::<i32>();
    let mut texts = StringBuilder::with_capacity(comment.len(), comment.value_data().len());
    let mut buf = String::new();
    for c in comment {
        match c {
            Some(c) => {
                buf.clear();
                normalize(c, &mut buf);
                texts.append_value(&buf);
            }
            None => texts.append_null(),
        }
    }
    let texts = texts.finish();
    let lens = length(&texts).unwrap();

    let flag = pick("returnflag");
    let status = pick("linestatus");
    let (flag, status) = (flag.as_string::<i32>(), status.as_string::<i32>());
    let qty = quantity.as_primitive::<Decimal128Type>().values();
    let base = price.as_primitive::<Decimal128Type>().values();
    let mut totals = [Totals::default(); 6];
    for i in 0..flag.len() {
        let g = &mut totals[group_of(flag.value(i), status.value(i))];
        g.count += 1;
        g.qty += qty[i];
        g.base += base[i];
        g.disc += if disc.is_valid(i) { disc.value(i) } else { 0 };
        g.charge += if charge.is_valid(i) { charge.value(i) } else { 0 };
    }
    assemble(
        vec![orderkey, Arc::new(disc), Arc::new(charge), Arc::new(texts), lens],
        &totals,
    )
}

/// An array out through `to_ffi` and back in through `from_ffi`: what a
/// consumer of the C Data Interface gets, with no copy.
pub fn through_c(array: &dyn Array) -> ArrayRef {
    let (c_array, c_schema) = to_ffi(&array.to_data()).expect("arrow-rs exports the array");
    // SAFETY: the pair comes from to_ffi of a valid array.
    make_array(unsafe { from_ffi(c_array, &c_schema) }.expect("arrow-rs imports the array"))
}

/// Who runs the job.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Way {
    RustRows,
    RustKernels,
    /// The Roc entry point: with `Feed::TYPED` Roc checks the text as
    /// UTF-8; with `Feed::TRUSTED` the host vouches for it.
    Roc(Feed),
    /// The same job in Roc with a `Str` per text read and write.
    RocStr(Feed),
}

impl Way {
    pub const ALL: [Way; 6] = [
        Way::RustRows,
        Way::RustKernels,
        Way::Roc(Feed::TYPED),
        Way::Roc(Feed::TRUSTED),
        Way::RocStr(Feed::TYPED),
        Way::RocStr(Feed::TRUSTED),
    ];

    pub fn name(self) -> &'static str {
        match self {
            Way::RustRows => "arrow-rs rows",
            Way::RustKernels => "arrow-rs kernels",
            Way::Roc(f) if f.trusted_text => "Roc, trusted text",
            Way::Roc(_) => "Roc, checked text",
            Way::RocStr(f) if f.trusted_text => "Roc Str, trusted text",
            Way::RocStr(_) => "Roc Str, checked text",
        }
    }

    pub fn parse(s: &str) -> Option<Way> {
        match s {
            "rust-rows" => Some(Way::RustRows),
            "rust-kernels" => Some(Way::RustKernels),
            "roc-checked" => Some(Way::Roc(Feed::TYPED)),
            "roc-trusted" => Some(Way::Roc(Feed::TRUSTED)),
            "roc-str-checked" => Some(Way::RocStr(Feed::TYPED)),
            "roc-str-trusted" => Some(Way::RocStr(Feed::TRUSTED)),
            _ => None,
        }
    }
}

/// How far a phase run goes. Each phase includes the ones before it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Phase {
    /// Roc only: the host makes its `Host` values from the C array.
    Host,
    /// The import: the C array to the typed column views.
    Import,
    /// The import, the filter, the prices and the totals; no text, no export.
    /// The arrow-rs kernels stop after the import here.
    Numeric,
    /// The whole job.
    Full,
}

/// The job on one batch, from the producer's array to the consumer's.
/// A phase short of `Full` gives `None`.
pub fn run_batch(way: Way, batch: &StructArray, phase: Phase) -> Option<ArrayRef> {
    match way {
        Way::Roc(feed) | Way::RocStr(feed) => {
            let entry = match (way, phase) {
                (Way::Roc(_), Phase::Host | Phase::Full) => "lineitem",
                (Way::Roc(_), Phase::Import) => "lineitem_import",
                (Way::Roc(_), Phase::Numeric) => "lineitem_numeric",
                (_, Phase::Host | Phase::Full) => "lineitem_str",
                (_, Phase::Import) => "lineitem_str_import",
                (_, Phase::Numeric) => "lineitem_str_numeric",
            };
            let input = HostInput::from_array(entry, batch, feed);
            match phase {
                Phase::Host => None,
                Phase::Import | Phase::Numeric => {
                    drop(input.run());
                    None
                }
                Phase::Full => Some(input.run().into_arrow_unvalidated(&output_type()).expect("Roc exports")),
            }
        }
        Way::RustRows | Way::RustKernels => {
            if phase == Phase::Host {
                return None;
            }
            let input = through_c(batch);
            let t = input.as_struct();
            match phase {
                Phase::Full => {
                    let out = if way == Way::RustRows {
                        by_rows(t)
                    } else {
                        by_kernels(t)
                    };
                    Some(through_c(out.as_ref()))
                }
                Phase::Numeric if way == Way::RustRows => {
                    drop(row_loop(t, false));
                    None
                }
                _ => None,
            }
        }
    }
}

/// One pass over every batch: the wall time, and the outputs when `keep`.
pub fn pass(way: Way, batches: &[StructArray], phase: Phase, keep: bool) -> (Duration, Vec<ArrayRef>) {
    let mut outs = Vec::new();
    let start = Instant::now();
    for b in batches {
        let out = run_batch(way, b, phase);
        if keep {
            outs.extend(out);
        }
    }
    (start.elapsed(), outs)
}

/// Check that `way` gives the output of [`by_rows`] on every batch, and
/// that the output passes `validate_full`.
pub fn check_way(way: Way, batches: &[StructArray]) -> Result<(), String> {
    for (k, b) in batches.iter().enumerate() {
        let want = by_rows(b);
        let got = run_batch(way, b, Phase::Full).expect("a full run gives an output");
        got.to_data()
            .validate_full()
            .map_err(|e| format!("{}: batch {k}: {e}", way.name()))?;
        if got.as_ref() != want.as_ref() {
            return Err(format!("{}: batch {k}: {}", way.name(), first_difference(&got, &want)));
        }
    }
    Ok(())
}

/// Where two outputs first differ: the field of `rows` or `groups`, and the row.
fn first_difference(got: &ArrayRef, want: &ArrayRef) -> String {
    if got.data_type() != want.data_type() {
        return format!("type {} is not {}", got.data_type(), want.data_type());
    }
    let (got, want) = (got.as_struct(), want.as_struct());
    for (list, name) in ["rows", "groups"].iter().enumerate() {
        let g = got.column(list).as_list::<i32>().value(0);
        let w = want.column(list).as_list::<i32>().value(0);
        let (g, w) = (g.as_struct(), w.as_struct());
        if g.len() != w.len() {
            return format!("{name}: {} rows, want {}", g.len(), w.len());
        }
        for (f, field) in g.fields().iter().enumerate() {
            let (gc, wc) = (g.column(f), w.column(f));
            if let Some(i) = (0..gc.len()).find(|i| gc.slice(*i, 1) != wc.slice(*i, 1)) {
                return format!(
                    "{name}.{} row {i}: {:?}, want {:?}",
                    field.name(),
                    gc.slice(i, 1),
                    wc.slice(i, 1)
                );
            }
        }
    }
    "the outputs differ".to_string()
}
