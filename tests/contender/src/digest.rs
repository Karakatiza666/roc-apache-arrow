//! The digest of the `digest` entry point, computed from arrow-rs reads.
//! The text of each value is the one `tests/contender/app.roc` documents.

use arrow::array::*;
use arrow::datatypes::*;

/// One text per row.
pub fn digests(array: &dyn Array) -> Vec<String> {
    (0..array.len()).map(|i| row(array, i)).collect()
}

fn hex(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(1 + 2 * bytes.len());
    s.push('x');
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn text(s: &str) -> String {
    format!("s{}:{s}", s.len())
}

/// The canonical quiet NaN of Roc's `to_bits`; every other value as is.
fn f64_bits(x: f64) -> u64 {
    if x.is_nan() {
        0x7FF8_0000_0000_0000
    } else {
        x.to_bits()
    }
}

fn f32_bits(x: f32) -> u32 {
    if x.is_nan() {
        0x7FC0_0000
    } else {
        x.to_bits()
    }
}

fn joined(child: &dyn Array) -> String {
    (0..child.len()).map(|j| row(child, j)).collect::<Vec<_>>().join(",")
}

/// The text of row `i`.
pub fn row(a: &dyn Array, i: usize) -> String {
    use DataType::*;
    if matches!(a.data_type(), Null) || a.is_null(i) {
        return "N".into();
    }
    macro_rules! prim {
        ($t:ty) => {
            a.as_primitive::<$t>().value(i).to_string()
        };
    }
    match a.data_type() {
        Boolean => (if a.as_boolean().value(i) { "t" } else { "f" }).into(),
        Int8 => prim!(Int8Type),
        Int16 => prim!(Int16Type),
        Int32 => prim!(Int32Type),
        Int64 => prim!(Int64Type),
        UInt8 => prim!(UInt8Type),
        UInt16 => prim!(UInt16Type),
        UInt32 => prim!(UInt32Type),
        UInt64 => prim!(UInt64Type),
        Float16 => a.as_primitive::<Float16Type>().value(i).to_bits().to_string(),
        Float32 => format!("f{}", f32_bits(a.as_primitive::<Float32Type>().value(i))),
        Float64 => format!("f{}", f64_bits(a.as_primitive::<Float64Type>().value(i))),
        Decimal32(_, _) => prim!(Decimal32Type),
        Decimal64(_, _) => prim!(Decimal64Type),
        Decimal128(_, _) => prim!(Decimal128Type),
        Date32 => prim!(Date32Type),
        Date64 => prim!(Date64Type),
        Time32(TimeUnit::Second) => prim!(Time32SecondType),
        Time32(_) => prim!(Time32MillisecondType),
        Time64(TimeUnit::Microsecond) => prim!(Time64MicrosecondType),
        Time64(_) => prim!(Time64NanosecondType),
        Timestamp(TimeUnit::Second, _) => prim!(TimestampSecondType),
        Timestamp(TimeUnit::Millisecond, _) => prim!(TimestampMillisecondType),
        Timestamp(TimeUnit::Microsecond, _) => prim!(TimestampMicrosecondType),
        Timestamp(TimeUnit::Nanosecond, _) => prim!(TimestampNanosecondType),
        Duration(TimeUnit::Second) => prim!(DurationSecondType),
        Duration(TimeUnit::Millisecond) => prim!(DurationMillisecondType),
        Duration(TimeUnit::Microsecond) => prim!(DurationMicrosecondType),
        Duration(TimeUnit::Nanosecond) => prim!(DurationNanosecondType),
        Utf8 => text(a.as_string::<i32>().value(i)),
        LargeUtf8 => text(a.as_string::<i64>().value(i)),
        Utf8View => text(a.as_string_view().value(i)),
        Binary => hex(a.as_binary::<i32>().value(i)),
        LargeBinary => hex(a.as_binary::<i64>().value(i)),
        BinaryView => hex(a.as_binary_view().value(i)),
        FixedSizeBinary(_) => hex(a.as_fixed_size_binary().value(i)),
        List(_) => format!("[{}]", joined(&a.as_list::<i32>().value(i))),
        LargeList(_) => format!("[{}]", joined(&a.as_list::<i64>().value(i))),
        FixedSizeList(_, _) => format!("[{}]", joined(&a.as_fixed_size_list().value(i))),
        Struct(_) => {
            let s = a.as_struct();
            format!(
                "{{{}}}",
                s.columns().iter().map(|c| row(c, i)).collect::<Vec<_>>().join(",")
            )
        }
        Map(_, _) => {
            let entries = a.as_map().value(i);
            let pairs: Vec<String> = (0..entries.len())
                .map(|j| format!("{}={}", row(entries.column(0), j), row(entries.column(1), j)))
                .collect();
            format!("{{{}}}", pairs.join(","))
        }
        other => panic!("no digest for {other}"),
    }
}
