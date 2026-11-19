//! Seeded random arrow-rs arrays over the type matrix of the package.
//! A case is reproducible from its seed alone.

use std::sync::Arc;

use arrow::array::*;
use arrow::buffer::{BooleanBuffer, Buffer, NullBuffer, OffsetBuffer, ScalarBuffer};
use arrow::datatypes::{DataType, Field, Fields, TimeUnit};

/// SplitMix64: small, fast and good enough for test data.
#[derive(Clone, Debug)]
pub struct Rng(u64);

impl Rng {
    pub fn new(seed: u64) -> Rng {
        Rng(seed)
    }

    pub fn next_u64(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A number in `0 .. n`; 0 when `n` is 0.
    pub fn below(&mut self, n: usize) -> usize {
        if n == 0 {
            0
        } else {
            (self.next_u64() % n as u64) as usize
        }
    }

    /// True with probability `percent` / 100.
    pub fn chance(&mut self, percent: usize) -> bool {
        self.below(100) < percent
    }

    pub fn pick<'a, T>(&mut self, xs: &'a [T]) -> &'a T {
        &xs[self.below(xs.len())]
    }

    pub fn bytes(&mut self, n: usize) -> Vec<u8> {
        (0..n).map(|_| self.next_u64() as u8).collect()
    }
}

/// The seed of case `index` of a run with seed `base`.
pub fn case_seed(base: u64, index: u64) -> u64 {
    Rng::new(base ^ index.wrapping_mul(0xA24B_AED4_963E_E407)).next_u64()
}

/// How many rows are NULL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Nulls {
    None,
    Some,
    All,
}

/// Every leaf type of the matrix.
pub fn leaf_types() -> Vec<DataType> {
    use DataType::*;
    vec![
        Null,
        Boolean,
        Int8,
        Int16,
        Int32,
        Int64,
        UInt8,
        UInt16,
        UInt32,
        UInt64,
        Float16,
        Float32,
        Float64,
        Decimal32(9, 2),
        Decimal64(18, 3),
        Decimal128(38, 5),
        Date32,
        Date64,
        Time32(TimeUnit::Second),
        Time32(TimeUnit::Millisecond),
        Time64(TimeUnit::Microsecond),
        Time64(TimeUnit::Nanosecond),
        Timestamp(TimeUnit::Second, None),
        Timestamp(TimeUnit::Millisecond, Some("UTC".into())),
        Timestamp(TimeUnit::Microsecond, Some("+05:30".into())),
        Timestamp(TimeUnit::Nanosecond, Some("Asia/Tokyo".into())),
        Duration(TimeUnit::Second),
        Duration(TimeUnit::Millisecond),
        Duration(TimeUnit::Microsecond),
        Duration(TimeUnit::Nanosecond),
        Utf8,
        LargeUtf8,
        Utf8View,
        Binary,
        LargeBinary,
        BinaryView,
        FixedSizeBinary(1),
        FixedSizeBinary(5),
        FixedSizeBinary(16),
    ]
}

/// A random type; nested types down to `depth` more levels.
pub fn random_type(rng: &mut Rng, depth: usize) -> DataType {
    if depth == 0 || rng.chance(45) {
        return rng.pick(&leaf_types()).clone();
    }
    let field = |rng: &mut Rng, name: &str| Arc::new(Field::new(name, random_type(rng, depth - 1), true));
    match rng.below(6) {
        0 => DataType::List(field(rng, "item")),
        1 => DataType::LargeList(field(rng, "item")),
        2 => DataType::FixedSizeList(field(rng, "item"), rng.below(4) as i32),
        3 | 4 => {
            let n = 1 + rng.below(3);
            DataType::Struct((0..n).map(|k| field(rng, &format!("f{k}"))).collect::<Vec<_>>().into())
        }
        _ => {
            let keys = loop {
                let t = rng.pick(&leaf_types()).clone();
                if t != DataType::Null {
                    break t;
                }
            };
            let entries = Fields::from(vec![
                Field::new("key", keys, false),
                Field::new("value", random_type(rng, depth - 1), true),
            ]);
            DataType::Map(Arc::new(Field::new("entries", DataType::Struct(entries), false)), false)
        }
    }
}

fn null_buffer(rng: &mut Rng, len: usize, nulls: Nulls) -> Option<NullBuffer> {
    match nulls {
        Nulls::None => None,
        Nulls::All => Some(NullBuffer::new_null(len)),
        Nulls::Some => {
            let percent = 10 + rng.below(60);
            let valid: Vec<bool> = (0..len).map(|_| !rng.chance(percent)).collect();
            Some(NullBuffer::from(valid))
        }
    }
}

/// A random NULL mode, mostly with some NULLs.
pub fn random_nulls(rng: &mut Rng) -> Nulls {
    match rng.below(10) {
        0..=2 => Nulls::None,
        3 => Nulls::All,
        _ => Nulls::Some,
    }
}

const ALPHABETS: [&[&str]; 4] = [
    &["a", "b", "z", "Q", "0", "9", " ", "_", "~"],
    &["à", "é", "î", "õ", "ü", "ç", "ñ", "ß", "e"],
    &["日", "本", "語", "中", "文", "한", "국", "어"],
    &["😀", "🎉", "🚀", "👍🏽", "🇨🇭", "a"],
];

/// Text from one alphabet or a mix of all, with lengths around the inline
/// limits of a view (12 bytes) and of a small Roc `Str` (23 bytes).
pub fn random_text(rng: &mut Rng) -> String {
    let n = match rng.below(10) {
        0 => 0,
        1..=6 => rng.below(14),
        7 | 8 => rng.below(30),
        _ => rng.below(120),
    };
    let mixed = rng.chance(25);
    let one = rng.below(ALPHABETS.len());
    (0..n)
        .map(|_| {
            let a = if mixed { rng.below(ALPHABETS.len()) } else { one };
            *rng.pick(ALPHABETS[a])
        })
        .collect()
}

fn random_bytes(rng: &mut Rng) -> Vec<u8> {
    let n = match rng.below(10) {
        0 => 0,
        1..=6 => rng.below(14),
        _ => rng.below(60),
    };
    rng.bytes(n)
}

fn float_bits64(rng: &mut Rng) -> u64 {
    match rng.below(12) {
        0 => 0,
        1 => (-0.0f64).to_bits(),
        2 => f64::INFINITY.to_bits(),
        3 => f64::NEG_INFINITY.to_bits(),
        4 => f64::NAN.to_bits(),
        // A NaN with a payload, quiet or signalling.
        5 => 0x7FF0_0000_0000_0000 | (rng.next_u64() & 0x000F_FFFF_FFFF_FFFF).max(1),
        6 => rng.next_u64() & 0x000F_FFFF_FFFF_FFFF,
        7 => (rng.below(2000) as f64 - 1000.0).to_bits(),
        _ => rng.next_u64(),
    }
}

fn float_bits32(rng: &mut Rng) -> u32 {
    match rng.below(12) {
        0 => 0,
        1 => (-0.0f32).to_bits(),
        2 => f32::INFINITY.to_bits(),
        3 => f32::NAN.to_bits(),
        4 => 0x7F80_0000 | ((rng.next_u64() as u32) & 0x007F_FFFF).max(1),
        5 => (rng.next_u64() as u32) & 0x007F_FFFF,
        6 => (rng.below(2000) as f32 - 1000.0).to_bits(),
        _ => rng.next_u64() as u32,
    }
}

/// The values buffer of a fixed-width type: `len` random values.
fn fixed_values(rng: &mut Rng, dt: &DataType, len: usize) -> Buffer {
    use DataType::*;
    match dt {
        Float64 => Buffer::from_vec((0..len).map(|_| float_bits64(rng)).collect::<Vec<u64>>()),
        Float32 => Buffer::from_vec((0..len).map(|_| float_bits32(rng)).collect::<Vec<u32>>()),
        Decimal128(_, _) => Buffer::from_vec((0..len).map(|_| small_or_wide(rng)).collect::<Vec<i128>>()),
        _ => {
            let width = crate::import::value_tag(dt).width();
            let width = match dt {
                FixedSizeBinary(w) => *w as usize,
                _ => width,
            };
            Buffer::from_slice_ref(rng.bytes(len * width))
        }
    }
}

fn small_or_wide(rng: &mut Rng) -> i128 {
    let wide = ((rng.next_u64() as u128) << 64 | rng.next_u64() as u128) as i128;
    match rng.below(4) {
        0 => rng.below(1000) as i128 - 500,
        1 => -wide,
        _ => wide,
    }
}

/// A random array of `len` rows. It is often cut from a longer one, so it
/// has an offset at its own level.
pub fn random_array(rng: &mut Rng, dt: &DataType, len: usize, nulls: Nulls) -> ArrayRef {
    let pre = if rng.chance(30) { rng.below(9) } else { 0 };
    let post = if rng.chance(30) { rng.below(5) } else { 0 };
    let full = build(rng, dt, pre + len + post, nulls);
    if pre + post == 0 {
        full
    } else {
        full.slice(pre, len)
    }
}

/// `random_array` with a random NULL mode.
pub fn any_array(rng: &mut Rng, dt: &DataType, len: usize) -> ArrayRef {
    let nulls = random_nulls(rng);
    random_array(rng, dt, len, nulls)
}

fn build(rng: &mut Rng, dt: &DataType, len: usize, nulls: Nulls) -> ArrayRef {
    use DataType::*;
    let nb = null_buffer(rng, len, nulls);
    match dt {
        Null => Arc::new(NullArray::new(len)),
        Boolean => {
            let values = BooleanBuffer::new(Buffer::from_slice_ref(rng.bytes(len.div_ceil(8))), 0, len);
            Arc::new(BooleanArray::new(values, nb))
        }
        Utf8 | LargeUtf8 | Utf8View => {
            let rows: Vec<Option<String>> = (0..len).map(|i| valid(&nb, i).then(|| random_text(rng))).collect();
            match dt {
                Utf8 => Arc::new(StringArray::from(rows)),
                LargeUtf8 => Arc::new(LargeStringArray::from(rows)),
                _ => Arc::new(StringViewArray::from(rows)),
            }
        }
        Binary | LargeBinary | BinaryView => {
            let rows: Vec<Option<Vec<u8>>> = (0..len).map(|i| valid(&nb, i).then(|| random_bytes(rng))).collect();
            let refs: Vec<Option<&[u8]>> = rows.iter().map(|r| r.as_deref()).collect();
            match dt {
                Binary => Arc::new(BinaryArray::from(refs)),
                LargeBinary => Arc::new(LargeBinaryArray::from(refs)),
                _ => Arc::new(BinaryViewArray::from(refs)),
            }
        }
        List(f) | LargeList(f) | Map(f, _) => {
            let (offsets, total) = list_offsets(rng, &nb, len);
            let child = if let Map(_, _) = dt {
                entries(rng, f, total)
            } else {
                any_array(rng, f.data_type(), total)
            };
            match dt {
                List(_) => Arc::new(ListArray::new(
                    f.clone(),
                    OffsetBuffer::new(ScalarBuffer::from(offsets)),
                    child,
                    nb,
                )),
                LargeList(_) => {
                    let wide: Vec<i64> = offsets.iter().map(|&o| o as i64).collect();
                    Arc::new(LargeListArray::new(
                        f.clone(),
                        OffsetBuffer::new(ScalarBuffer::from(wide)),
                        child,
                        nb,
                    ))
                }
                _ => {
                    let entries = child.as_struct().clone();
                    Arc::new(MapArray::new(
                        f.clone(),
                        OffsetBuffer::new(ScalarBuffer::from(offsets)),
                        entries,
                        nb,
                        false,
                    ))
                }
            }
        }
        FixedSizeList(f, size) => {
            let child = any_array(rng, f.data_type(), len * *size as usize);
            Arc::new(
                FixedSizeListArray::try_new_with_length(f.clone(), *size, child, nb, len).expect("a fixed-size list"),
            )
        }
        Struct(fields) => {
            let kids: Vec<ArrayRef> = fields.iter().map(|f| any_array(rng, f.data_type(), len)).collect();
            Arc::new(StructArray::new(fields.clone(), kids, nb))
        }
        _ => {
            let data = ArrayData::builder(dt.clone())
                .len(len)
                .add_buffer(fixed_values(rng, dt, len))
                .nulls(nb)
                .build()
                .expect("a valid fixed-width array");
            make_array(data)
        }
    }
}

fn valid(nb: &Option<NullBuffer>, i: usize) -> bool {
    nb.as_ref().is_none_or(|n| n.is_valid(i))
}

/// Offsets of `len` list rows of 0 to 4 items. A NULL row is mostly
/// empty, but may keep items, as Arrow allows.
fn list_offsets(rng: &mut Rng, nb: &Option<NullBuffer>, len: usize) -> (Vec<i32>, usize) {
    let mut offsets = vec![0i32];
    let mut total = 0usize;
    for i in 0..len {
        let n = if valid(nb, i) || rng.chance(20) {
            rng.below(5)
        } else {
            0
        };
        total += n;
        offsets.push(total as i32);
    }
    (offsets, total)
}

/// The entries of a map: keys with no NULL, values of any kind.
fn entries(rng: &mut Rng, f: &Arc<Field>, total: usize) -> ArrayRef {
    let DataType::Struct(kv) = f.data_type() else {
        panic!("map entries are a struct")
    };
    let keys = random_array(rng, kv[0].data_type(), total, Nulls::None);
    let values = any_array(rng, kv[1].data_type(), total);
    Arc::new(StructArray::new(kv.clone(), vec![keys, values], None))
}

/// A random case: a type down to depth 3, 0 to 40 rows (mostly short), a
/// NULL mode.
pub fn random_case(seed: u64) -> ArrayRef {
    let mut rng = Rng::new(seed);
    let dt = random_type(&mut rng, 3);
    let len = match rng.below(10) {
        0 => 0,
        1..=7 => 1 + rng.below(12),
        _ => rng.below(41),
    };
    let nulls = random_nulls(&mut rng);
    random_array(&mut rng, &dt, len, nulls)
}
