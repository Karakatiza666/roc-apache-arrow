//! The invalid corpus: a valid array broken at the buffer level, at its root
//! or at a nested child. Each mutant keeps its true buffer sizes, so a short
//! buffer reaches Roc as a short list (see `HostInput::from_data`).

use arrow::array::ArrayData;
use arrow::buffer::Buffer;
use arrow::datatypes::{DataType, Field};

use crate::gen::Rng;

/// What a mutation breaks.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Kind {
    /// An offset lower than the one before it.
    OffsetsDecrease,
    /// The last offset past the data or the child.
    OffsetPastEnd,
    /// The first offset below 0.
    NegativeOffset,
    /// The values buffer shorter than offset + length values.
    ShortValues,
    /// The offsets buffer shorter than offset + length + 1 offsets.
    ShortOffsets,
    /// A byte that is not UTF-8 in a text value.
    BadUtf8,
    /// A text offset in the middle of a character; the bytes stay UTF-8.
    SplitCodePoint,
    /// A view that names a data buffer that does not exist.
    ViewIndex,
    /// A view that ends past its data buffer.
    ViewPastEnd,
    /// A view whose prefix is not the first 4 bytes of its value.
    ViewPrefix,
    /// An inline view with a byte set after its value.
    ViewPadding,
    /// A child shorter than its parent needs.
    ChildShort,
    /// A `null_count` that is not the count of 0 bits.
    NullCountLie,
    /// NULLs in the child of a field that is not nullable.
    NonNullableNulls,
}

pub const KINDS: [Kind; 14] = [
    Kind::OffsetsDecrease,
    Kind::OffsetPastEnd,
    Kind::NegativeOffset,
    Kind::ShortValues,
    Kind::ShortOffsets,
    Kind::BadUtf8,
    Kind::SplitCodePoint,
    Kind::ViewIndex,
    Kind::ViewPastEnd,
    Kind::ViewPrefix,
    Kind::ViewPadding,
    Kind::ChildShort,
    Kind::NullCountLie,
    Kind::NonNullableNulls,
];

/// A broken copy of an array, and where it was broken.
pub struct Mutant {
    pub kind: Kind,
    pub path: Vec<usize>,
    pub data: ArrayData,
}

/// Every node of the tree, as the child indexes that lead to it.
fn paths(data: &ArrayData, prefix: Vec<usize>, out: &mut Vec<Vec<usize>>) {
    out.push(prefix.clone());
    for (i, kid) in data.child_data().iter().enumerate() {
        let mut p = prefix.clone();
        p.push(i);
        paths(kid, p, out);
    }
}

fn node<'a>(data: &'a ArrayData, path: &[usize]) -> &'a ArrayData {
    path.iter().fold(data, |d, &i| &d.child_data()[i])
}

/// `root` with the node at `path` replaced. Nothing is checked.
fn replace(root: &ArrayData, path: &[usize], new: ArrayData) -> ArrayData {
    let Some((&first, rest)) = path.split_first() else {
        return new;
    };
    let mut kids = root.child_data().to_vec();
    kids[first] = replace(&kids[first], rest, new);
    unsafe { root.clone().into_builder().child_data(kids).build_unchecked() }
}

fn with_buffer(d: &ArrayData, index: usize, bytes: Vec<u8>) -> ArrayData {
    let mut bufs = d.buffers().to_vec();
    bufs[index] = Buffer::from_slice_ref(bytes);
    unsafe { d.clone().into_builder().buffers(bufs).build_unchecked() }
}

/// Offsets as i64, whatever their width.
fn read_offsets(d: &ArrayData) -> (Vec<i64>, usize) {
    let b = d.buffers()[0].as_slice();
    if is_large(d.data_type()) {
        (b.as_chunks::<8>().0.iter().map(|c| i64::from_le_bytes(*c)).collect(), 8)
    } else {
        (
            b.as_chunks::<4>()
                .0
                .iter()
                .map(|c| i32::from_le_bytes(*c) as i64)
                .collect(),
            4,
        )
    }
}

fn write_offsets(d: &ArrayData, offs: &[i64]) -> ArrayData {
    let bytes = if is_large(d.data_type()) {
        offs.iter().flat_map(|o| o.to_le_bytes()).collect()
    } else {
        offs.iter().flat_map(|o| (*o as i32).to_le_bytes()).collect()
    };
    with_buffer(d, 0, bytes)
}

fn is_large(dt: &DataType) -> bool {
    matches!(dt, DataType::LargeUtf8 | DataType::LargeBinary | DataType::LargeList(_))
}

fn has_offsets(dt: &DataType) -> bool {
    use DataType::*;
    matches!(
        dt,
        Utf8 | LargeUtf8 | Binary | LargeBinary | List(_) | LargeList(_) | Map(_, _)
    )
}

fn is_text(dt: &DataType) -> bool {
    matches!(dt, DataType::Utf8 | DataType::LargeUtf8)
}

fn is_view(dt: &DataType) -> bool {
    matches!(dt, DataType::Utf8View | DataType::BinaryView)
}

/// The byte width of a fixed-width type, or 0 for Boolean (bits).
fn fixed_width(dt: &DataType) -> Option<usize> {
    use DataType::*;
    match dt {
        Boolean => Some(0),
        FixedSizeBinary(w) => Some(*w as usize),
        Null
        | Utf8
        | LargeUtf8
        | Utf8View
        | Binary
        | LargeBinary
        | BinaryView
        | List(_)
        | LargeList(_)
        | FixedSizeList(_, _)
        | Struct(_)
        | Map(_, _) => None,
        other => Some(crate::import::value_tag(other).width()),
    }
}

/// The limit the last offset may reach: the data bytes or the child rows.
fn offsets_limit(d: &ArrayData) -> i64 {
    match d.data_type() {
        DataType::List(_) | DataType::LargeList(_) | DataType::Map(_, _) => d.child_data()[0].len() as i64,
        _ => d.buffers()[1].len() as i64,
    }
}

fn views(d: &ArrayData) -> Vec<u128> {
    d.buffers()[0]
        .as_slice()
        .as_chunks::<16>()
        .0
        .iter()
        .map(|c| u128::from_le_bytes(*c))
        .collect()
}

fn write_views(d: &ArrayData, vs: &[u128]) -> ArrayData {
    with_buffer(d, 0, vs.iter().flat_map(|v| v.to_le_bytes()).collect())
}

/// The rows of a node: `offset .. offset + len`.
fn rows(d: &ArrayData) -> std::ops::Range<usize> {
    d.offset()..d.offset() + d.len()
}

/// Apply `kind` at the node `d`, or `None` when the node cannot take it.
fn mutate_node(rng: &mut Rng, kind: Kind, d: &ArrayData) -> Option<ArrayData> {
    let dt = d.data_type();
    let r = rows(d);
    match kind {
        Kind::OffsetsDecrease if has_offsets(dt) && !r.is_empty() => {
            let (mut offs, _) = read_offsets(d);
            let i = r.start + 1 + rng.below(r.len());
            if offs[i - 1] >= 1 {
                offs[i] = offs[i - 1] - 1 - rng.below(offs[i - 1] as usize) as i64;
            } else {
                offs[i - 1] = offs[i] + 1 + rng.below(3) as i64;
            }
            Some(write_offsets(d, &offs))
        }
        Kind::OffsetPastEnd if has_offsets(dt) => {
            let (mut offs, _) = read_offsets(d);
            offs[r.end] = offsets_limit(d) + 1 + rng.below(10) as i64;
            Some(write_offsets(d, &offs))
        }
        Kind::NegativeOffset if has_offsets(dt) => {
            let (mut offs, _) = read_offsets(d);
            offs[r.start] = -1 - rng.below(5) as i64;
            Some(write_offsets(d, &offs))
        }
        Kind::ShortOffsets if has_offsets(dt) => {
            let (offs, w) = read_offsets(d);
            let need = (r.end + 1) * w;
            let keep = rng.below(need / w) * w;
            Some(with_buffer(
                d,
                0,
                d.buffers()[0].as_slice()[..keep.min(offs.len() * w)].to_vec(),
            ))
        }
        Kind::ShortValues if !r.is_empty() => {
            let w = fixed_width(dt)?;
            let need = if w == 0 { r.end.div_ceil(8) } else { r.end * w };
            if need == 0 {
                return None;
            }
            let keep = rng.below(need);
            Some(with_buffer(d, 0, d.buffers()[0].as_slice()[..keep].to_vec()))
        }
        Kind::BadUtf8 if is_text(dt) => {
            let (offs, _) = read_offsets(d);
            let (lo, hi) = (offs[r.start] as usize, offs[r.end] as usize);
            if hi <= lo {
                return None;
            }
            let mut data = d.buffers()[1].as_slice().to_vec();
            data[lo + rng.below(hi - lo)] = 0xFF;
            Some(with_buffer(d, 1, data))
        }
        Kind::BadUtf8 if *dt == DataType::Utf8View => {
            let mut vs = views(d);
            let i = r.clone().find(|&i| (vs[i] as u32) > 0)?;
            let len = vs[i] as u32 as usize;
            if len <= 12 {
                let byte = 4 + rng.below(len);
                vs[i] |= 0xFFu128 << (8 * byte);
                Some(write_views(d, &vs))
            } else {
                let index = (vs[i] >> 64) as u32 as usize;
                let start = (vs[i] >> 96) as u32 as usize;
                let mut data = d.buffers()[1 + index].as_slice().to_vec();
                data[start + 4 + rng.below(len - 4)] = 0xFF;
                let mut bufs = d.buffers().to_vec();
                bufs[1 + index] = Buffer::from_slice_ref(data);
                Some(unsafe { d.clone().into_builder().buffers(bufs).build_unchecked() })
            }
        }
        Kind::SplitCodePoint if is_text(dt) && !r.is_empty() => {
            let (mut offs, _) = read_offsets(d);
            let data = d.buffers()[1].as_slice();
            // An offset at the lead byte of a character of 2 or more bytes,
            // whose row (or the row before) holds the next byte too.
            let candidates: Vec<usize> = (r.start..r.end)
                .filter(|&i| {
                    let p = offs[i] as usize;
                    p < data.len() && data[p] >= 0xC0 && offs[i + 1] as usize > p
                })
                .collect();
            if candidates.is_empty() {
                return None;
            }
            let i = *rng.pick(&candidates);
            offs[i] += 1;
            Some(write_offsets(d, &offs))
        }
        Kind::ViewIndex | Kind::ViewPastEnd | Kind::ViewPrefix if is_view(dt) => {
            let mut vs = views(d);
            let long: Vec<usize> = r.clone().filter(|&i| (vs[i] as u32) > 12).collect();
            if long.is_empty() {
                return None;
            }
            let i = *rng.pick(&long);
            let len = vs[i] as u32 as u128;
            let n_data = d.buffers().len() - 1;
            let index = (vs[i] >> 64) as u32 as usize;
            let low = vs[i] & ((1u128 << 64) - 1);
            vs[i] = match kind {
                Kind::ViewIndex => low | (((n_data + rng.below(3)) as u128) << 64) | ((vs[i] >> 96) << 96),
                Kind::ViewPastEnd => {
                    let buf_len = d.buffers()[1 + index].len() as u128;
                    let start = buf_len + 1 + rng.below(8) as u128 - len.min(buf_len);
                    (vs[i] & ((1u128 << 96) - 1)) | (start << 96)
                }
                _ => vs[i] ^ (1u128 << (32 + rng.below(32))),
            };
            Some(write_views(d, &vs))
        }
        Kind::ViewPadding if is_view(dt) => {
            let mut vs = views(d);
            let short: Vec<usize> = r.clone().filter(|&i| (vs[i] as u32) < 12).collect();
            if short.is_empty() {
                return None;
            }
            let i = *rng.pick(&short);
            let len = vs[i] as u32 as usize;
            let byte = 4 + len + rng.below(12 - len);
            vs[i] |= (1 + rng.below(255) as u128) << (8 * byte);
            Some(write_views(d, &vs))
        }
        Kind::ChildShort if !r.is_empty() => {
            let (k, need) = match dt {
                DataType::Struct(fs) if !fs.is_empty() => (rng.below(fs.len()), r.end),
                DataType::FixedSizeList(_, size) if *size > 0 => (0, r.end * *size as usize),
                DataType::List(_) | DataType::LargeList(_) | DataType::Map(_, _) => {
                    let (offs, _) = read_offsets(d);
                    (0, offs[r.end].max(0) as usize)
                }
                _ => return None,
            };
            if need == 0 {
                return None;
            }
            let mut kids = d.child_data().to_vec();
            kids[k] = kids[k].slice(0, rng.below(need).min(kids[k].len()));
            Some(unsafe { d.clone().into_builder().child_data(kids).build_unchecked() })
        }
        _ => None,
    }
}

/// A copy of `root` whose `null_count` lies, or `None` when it has no bitmap.
fn null_count_lie(rng: &mut Rng, root: &ArrayData) -> Option<ArrayData> {
    let nulls = root.nulls()?;
    let actual = nulls.null_count();
    let lie = if actual > 0 && rng.chance(50) {
        0
    } else {
        actual + 1 + rng.below(3)
    };
    // A bitmap from bit 0 at the array's own offset, as new_unchecked takes it.
    let mut bits = vec![0u8; (root.offset() + root.len()).div_ceil(8)];
    for i in 0..root.len() {
        if nulls.is_valid(i) {
            let b = root.offset() + i;
            bits[b / 8] |= 1 << (b % 8);
        }
    }
    Some(unsafe {
        ArrayData::new_unchecked(
            root.data_type().clone(),
            root.len(),
            Some(lie),
            Some(Buffer::from_vec(bits)),
            root.offset(),
            root.buffers().to_vec(),
            root.child_data().to_vec(),
        )
    })
}

/// The root list type with a non-nullable item field over a child with NULLs.
fn non_nullable(root: &ArrayData) -> Option<ArrayData> {
    let child = root.child_data().first()?;
    if child.null_count() == 0 {
        return None;
    }
    let strict = |f: &Field| std::sync::Arc::new(f.clone().with_nullable(false));
    let dt = match root.data_type() {
        DataType::List(f) => DataType::List(strict(f)),
        DataType::LargeList(f) => DataType::LargeList(strict(f)),
        DataType::FixedSizeList(f, n) => DataType::FixedSizeList(strict(f), *n),
        _ => return None,
    };
    Some(unsafe { root.clone().into_builder().data_type(dt).build_unchecked() })
}

/// A mutant of kind `kind` at a random node of `root` that can take it.
pub fn mutate(rng: &mut Rng, kind: Kind, root: &ArrayData) -> Option<Mutant> {
    match kind {
        Kind::NullCountLie => {
            return null_count_lie(rng, root).map(|data| Mutant {
                kind,
                path: vec![],
                data,
            })
        }
        Kind::NonNullableNulls => {
            return non_nullable(root).map(|data| Mutant {
                kind,
                path: vec![],
                data,
            })
        }
        _ => {}
    }
    let mut all = vec![];
    paths(root, vec![], &mut all);
    // Try the nodes in a random order.
    for _ in 0..all.len() {
        let k = rng.below(all.len());
        let path = all.swap_remove(k);
        if let Some(new) = mutate_node(rng, kind, node(root, &path)) {
            let data = replace(root, &path, new);
            return Some(Mutant { kind, path, data });
        }
    }
    None
}
