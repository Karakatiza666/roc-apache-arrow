//! arrow-rs to Roc: an arrow-rs array goes out through the C Data Interface
//! (`FFI_ArrowArray`, `FFI_ArrowSchema`), and the host wraps each C buffer
//! as a static Roc list with zero copy, as a C host does.
//!
//! A C `ArrowArray` holds no buffer sizes, so the host computes them from the
//! type, the length, the offset and the offsets buffers ([`c_sizes`]). The
//! invalid corpus passes the true sizes of its buffers instead
//! ([`HostInput::from_data`]), so a short buffer reaches Roc as a short list.

use arrow::array::{Array, ArrayData};
use arrow::datatypes::DataType;
use arrow::ffi::{to_ffi, FFI_ArrowArray, FFI_ArrowSchema};

use crate::roc::{self, static_list, static_str, HostArray, HostBuffer, HostSchema, RocList, Tag};

/// How the host hands buffers to Roc.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Feed {
    /// Typed lists (`I64s`, `I32s`, ...) where the pointer is aligned;
    /// `false` passes every buffer as `U8s`, and Roc copies it.
    pub typed: bool,
    /// The data buffer of Utf8 and LargeUtf8 as a trusted `Str` (`Utf8`).
    pub trusted_text: bool,
}

impl Feed {
    pub const TYPED: Feed = Feed {
        typed: true,
        trusted_text: false,
    };
    pub const BYTES: Feed = Feed {
        typed: false,
        trusted_text: false,
    };
    pub const TRUSTED: Feed = Feed {
        typed: true,
        trusted_text: true,
    };
    pub const ALL: [Feed; 3] = [Feed::TYPED, Feed::BYTES, Feed::TRUSTED];
}

/// The role of one C buffer, which picks its `Host.Buffer` variant.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Validity,
    Values(Tag),
    Offsets(Tag),
    Data { text: bool },
    Views,
    ViewData,
    ViewSizes,
}

/// The roles of the C buffers of a node of this type, in C order. A view
/// type has `n_buffers - 3` data buffers.
pub fn roles(dt: &DataType, n_buffers: usize) -> Vec<Role> {
    use DataType::*;
    let v = Role::Validity;
    match dt {
        Null => vec![],
        Boolean => vec![v, Role::Values(Tag::U8s)],
        Utf8 => vec![v, Role::Offsets(Tag::I32s), Role::Data { text: true }],
        Binary => vec![v, Role::Offsets(Tag::I32s), Role::Data { text: false }],
        LargeUtf8 => vec![v, Role::Offsets(Tag::I64s), Role::Data { text: true }],
        LargeBinary => vec![v, Role::Offsets(Tag::I64s), Role::Data { text: false }],
        Utf8View | BinaryView => {
            let mut r = vec![v, Role::Views];
            r.extend(std::iter::repeat_n(Role::ViewData, n_buffers.saturating_sub(3)));
            r.push(Role::ViewSizes);
            r
        }
        FixedSizeBinary(_) => vec![v, Role::Values(Tag::U8s)],
        List(_) | Map(_, _) => vec![v, Role::Offsets(Tag::I32s)],
        LargeList(_) => vec![v, Role::Offsets(Tag::I64s)],
        FixedSizeList(_, _) | Struct(_) => vec![v],
        other => vec![v, Role::Values(value_tag(other))],
    }
}

/// The typed list of a fixed-width type's values.
pub fn value_tag(dt: &DataType) -> Tag {
    use DataType::*;
    match dt {
        Int8 => Tag::I8s,
        Int16 => Tag::I16s,
        Int32 | Date32 | Time32(_) | Decimal32(_, _) => Tag::I32s,
        Int64 | Date64 | Time64(_) | Timestamp(_, _) | Duration(_) | Decimal64(_, _) => Tag::I64s,
        UInt8 => Tag::U8s,
        UInt16 | Float16 => Tag::U16s,
        UInt32 => Tag::U32s,
        UInt64 => Tag::U64s,
        Float32 => Tag::F32s,
        Float64 => Tag::F64s,
        Decimal128(_, _) => Tag::I128s,
        _ => Tag::U8s,
    }
}

fn byte_width(dt: &DataType) -> usize {
    use DataType::*;
    match dt {
        Decimal256(_, _) => 32,
        FixedSizeBinary(w) => *w as usize,
        Interval(arrow::datatypes::IntervalUnit::MonthDayNano) => 16,
        Interval(arrow::datatypes::IntervalUnit::DayTime) => 8,
        Interval(arrow::datatypes::IntervalUnit::YearMonth) => 4,
        other => value_tag(other).width(),
    }
}

/// The byte size of each C buffer, computed as a C host computes it: from
/// the length and offset, the last offset of an offsets buffer, and the
/// sizes buffer of a view type.
///
/// # Safety
/// `ptrs` are the C buffers of a node of type `dt` with `len + offset` rows.
pub unsafe fn c_sizes(dt: &DataType, rows: usize, ptrs: &[*const u8]) -> Vec<usize> {
    let rs = roles(dt, ptrs.len());
    let n_data = rs.iter().filter(|r| **r == Role::ViewData).count();
    rs.iter()
        .enumerate()
        .map(|(i, role)| match role {
            Role::Validity => rows.div_ceil(8),
            Role::Values(_) if matches!(dt, DataType::Boolean) => rows.div_ceil(8),
            Role::Values(_) => rows * byte_width(dt),
            Role::Offsets(t) => (rows + 1) * t.width(),
            Role::Data { .. } => {
                let offs = ptrs[1];
                if offs.is_null() {
                    0
                } else if rs[1] == Role::Offsets(Tag::I32s) {
                    (offs as *const i32).add(rows).read_unaligned().max(0) as usize
                } else {
                    (offs as *const i64).add(rows).read_unaligned().max(0) as usize
                }
            }
            Role::Views => rows * 16,
            Role::ViewData => {
                let sizes = ptrs[ptrs.len() - 1] as *const i64;
                sizes.add(i - 2).read_unaligned().max(0) as usize
            }
            Role::ViewSizes => n_data * 8,
        })
        .collect()
}

/// An arrow-rs array as the `Host` values Roc takes. It owns every list it
/// hands Roc, and the C structs that own the arrow-rs buffers, so it can run
/// any number of entry points.
pub struct HostInput {
    pub array: HostArray,
    pub schema: HostSchema,
    arena: Arena,
    _c: (FFI_ArrowArray, FFI_ArrowSchema),
}

#[derive(Default)]
struct Arena {
    buffers: Vec<Vec<HostBuffer>>,
    arrays: Vec<Vec<HostArray>>,
    schemas: Vec<Vec<HostSchema>>,
    bytes: Vec<Vec<u8>>,
}

impl Arena {
    fn list_of<T: Copy>(&mut self, items: Vec<T>, keep: fn(&mut Arena, Vec<T>)) -> RocList {
        let list = static_list(items.as_ptr(), items.len());
        keep(self, items);
        list
    }

    fn bytes(&mut self, bytes: Vec<u8>) -> RocList {
        self.list_of(bytes, |a, v| a.bytes.push(v))
    }
}

impl HostInput {
    /// Export `array` through the C Data Interface; the host computes the
    /// buffer sizes. The root schema is named `entry`.
    pub fn from_array(entry: &str, array: &dyn Array, feed: Feed) -> HostInput {
        let data = array.to_data();
        let (c_array, c_schema) = to_ffi(&data).expect("arrow-rs exports the array");
        Self::build(entry, c_array, c_schema, data.data_type(), None, feed)
    }

    /// The C buffers of `data` with their true sizes, for data that may be
    /// invalid: no size is read from its offsets.
    pub fn from_data(entry: &str, data: &ArrayData, feed: Feed) -> HostInput {
        let c_array = FFI_ArrowArray::new(data);
        let c_schema = FFI_ArrowSchema::try_from(data.data_type()).expect("arrow-rs exports the type");
        Self::build(entry, c_array, c_schema, data.data_type(), Some(data), feed)
    }

    fn build(
        entry: &str,
        c_array: FFI_ArrowArray,
        c_schema: FFI_ArrowSchema,
        dt: &DataType,
        sized: Option<&ArrayData>,
        feed: Feed,
    ) -> HostInput {
        let mut arena = Arena::default();
        let array = unsafe { node(&mut arena, &c_array, dt, sized, feed) };
        let mut schema = schema_node(&mut arena, &c_schema);
        schema.name = arena.bytes(entry.as_bytes().to_vec());
        HostInput {
            array,
            schema,
            arena,
            _c: (c_array, c_schema),
        }
    }

    /// The same input under another entry point.
    pub fn with_entry(mut self, entry: &str) -> HostInput {
        self.schema.name = self.arena.bytes(entry.as_bytes().to_vec());
        self
    }

    /// Run the entry point. Roc reads the static lists and frees none of them.
    pub fn run(&self) -> crate::RocResult {
        crate::RocResult::new(roc::run(self.array, self.schema))
    }
}

/// # Safety
/// `c` is a live C array of type `dt`; `sized` (when given) is its source.
unsafe fn node(
    arena: &mut Arena,
    c: &FFI_ArrowArray,
    dt: &DataType,
    sized: Option<&ArrayData>,
    feed: Feed,
) -> HostArray {
    let ptrs: Vec<*const u8> = (0..c.num_buffers()).map(|i| c.buffer(i)).collect();
    let rs = roles(dt, ptrs.len());
    assert_eq!(rs.len(), ptrs.len(), "buffers of {dt}");
    let sizes = match sized {
        None => c_sizes(dt, c.len() + c.offset(), &ptrs),
        Some(data) => true_sizes(data, &rs),
    };
    let buffers: Vec<HostBuffer> = rs
        .iter()
        .zip(ptrs.iter().zip(sizes.iter()))
        .map(|(role, (&p, &size))| host_buffer(*role, p, size, feed))
        .collect();
    let kid_types: Vec<DataType> = match dt {
        DataType::List(f) | DataType::LargeList(f) | DataType::FixedSizeList(f, _) | DataType::Map(f, _) => {
            vec![f.data_type().clone()]
        }
        DataType::Struct(fs) => fs.iter().map(|f| f.data_type().clone()).collect(),
        _ => vec![],
    };
    let kids: Vec<HostArray> = kid_types
        .iter()
        .enumerate()
        .map(|(i, kdt)| node(arena, c.child(i), kdt, sized.map(|d| &d.child_data()[i]), feed))
        .collect();
    HostArray {
        length: c.len() as i64,
        null_count: c.null_count_opt().map_or(-1, |n| n as i64),
        offset: c.offset() as i64,
        buffers: arena.list_of(buffers, |a, v| a.buffers.push(v)),
        children: arena.list_of(kids, |a, v| a.arrays.push(v)),
        dictionary: static_list(std::ptr::null::<HostArray>(), 0),
    }
}

/// The sizes of the buffers `data` holds. No offset is read, so they hold
/// for invalid data too.
fn true_sizes(data: &ArrayData, rs: &[Role]) -> Vec<usize> {
    let rows = data.len() + data.offset();
    let mut held = data.buffers().iter().map(|b| b.len());
    let n_data = rs.iter().filter(|r| **r == Role::ViewData).count();
    rs.iter()
        .map(|role| match role {
            Role::Validity => rows.div_ceil(8),
            Role::ViewSizes => n_data * 8,
            _ => held.next().expect("a buffer per role"),
        })
        .collect()
}

fn host_buffer(role: Role, p: *const u8, size: usize, feed: Feed) -> HostBuffer {
    if p.is_null() {
        return HostBuffer::absent();
    }
    let bytes = || HostBuffer::list(Tag::U8s, static_list(p, size));
    let typed = |tag: Tag| {
        if feed.typed && (p as usize).is_multiple_of(tag.width()) {
            HostBuffer::list(tag, static_list(p, size / tag.width()))
        } else {
            bytes()
        }
    };
    match role {
        Role::Validity | Role::ViewData => bytes(),
        Role::Values(tag) | Role::Offsets(tag) => typed(tag),
        Role::Data { text } if text && feed.trusted_text => HostBuffer::utf8(static_str(p, size)),
        Role::Data { .. } => bytes(),
        Role::Views => typed(Tag::U32s),
        Role::ViewSizes => typed(Tag::I64s),
    }
}

fn schema_node(arena: &mut Arena, s: &FFI_ArrowSchema) -> HostSchema {
    let kids: Vec<HostSchema> = s.children().map(|k| schema_node(arena, k)).collect();
    let dictionary: Vec<HostSchema> = s.dictionary().map(|d| schema_node(arena, d)).into_iter().collect();
    let metadata = encode_metadata(&s.metadata().expect("schema metadata"));
    HostSchema {
        format: arena.bytes(s.format().as_bytes().to_vec()),
        name: arena.bytes(s.name().unwrap_or("").as_bytes().to_vec()),
        metadata: arena.bytes(metadata),
        flags: s.flags().map_or(0, |f| f.bits()),
        children: arena.list_of(kids, |a, v| a.schemas.push(v)),
        dictionary: arena.list_of(dictionary, |a, v| a.schemas.push(v)),
    }
}

/// The C binary encoding of metadata; empty for none.
fn encode_metadata(map: &std::collections::HashMap<String, String>) -> Vec<u8> {
    if map.is_empty() {
        return vec![];
    }
    let mut out = (map.len() as i32).to_le_bytes().to_vec();
    let mut pairs: Vec<_> = map.iter().collect();
    pairs.sort();
    for (k, v) in pairs {
        out.extend((k.len() as i32).to_le_bytes());
        out.extend(k.as_bytes());
        out.extend((v.len() as i32).to_le_bytes());
        out.extend(v.as_bytes());
    }
    out
}
