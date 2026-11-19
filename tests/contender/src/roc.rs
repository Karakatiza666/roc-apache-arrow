//! The Roc side of the link: the `Host` types as `repr(C)` structs (the
//! layout of `glue/roc_platform_abi.h`), the runtime hooks that compiled Roc
//! code calls, and static lists that wrap host memory with zero copy.

use std::cell::{Cell, RefCell};
use std::ffi::c_void;
use std::io::Write;

/// `RocList`: elements, length, capacity or allocation word.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct RocList {
    pub elements: *const c_void,
    pub length: usize,
    pub capacity_or_alloc_ptr: usize,
}

/// `RocStr`: bytes, capacity or allocation word, length (big form).
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct RocStr {
    pub bytes: *const u8,
    pub capacity_or_alloc_ptr: usize,
    pub length: usize,
}

/// `Host.Buffer`: a 24-byte payload and a tag.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct HostBuffer {
    payload: [usize; 3],
    pub tag: u8,
}

/// The tags of `Host.Buffer`, numbered as the glue header numbers them.
#[repr(u8)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tag {
    Absent = 0,
    F32s = 1,
    F64s = 2,
    I128s = 3,
    I16s = 4,
    I32s = 5,
    I64s = 6,
    I8s = 7,
    U16s = 8,
    U32s = 9,
    U64s = 10,
    U8s = 11,
    Utf8 = 12,
}

impl Tag {
    /// The element size in bytes of a list tag.
    pub fn width(self) -> usize {
        match self {
            Tag::Absent | Tag::Utf8 | Tag::I8s | Tag::U8s => 1,
            Tag::I16s | Tag::U16s => 2,
            Tag::F32s | Tag::I32s | Tag::U32s => 4,
            Tag::F64s | Tag::I64s | Tag::U64s => 8,
            Tag::I128s => 16,
        }
    }

    fn from_u8(tag: u8) -> Tag {
        assert!(tag <= 12, "unknown Host.Buffer tag {tag}");
        // SAFETY: Tag is repr(u8) with every value 0 ..= 12.
        unsafe { std::mem::transmute::<u8, Tag>(tag) }
    }
}

impl HostBuffer {
    pub fn absent() -> HostBuffer {
        HostBuffer {
            payload: [0; 3],
            tag: Tag::Absent as u8,
        }
    }

    pub fn list(tag: Tag, list: RocList) -> HostBuffer {
        assert!(tag != Tag::Absent && tag != Tag::Utf8);
        HostBuffer {
            payload: [list.elements as usize, list.length, list.capacity_or_alloc_ptr],
            tag: tag as u8,
        }
    }

    pub fn utf8(s: RocStr) -> HostBuffer {
        HostBuffer {
            payload: [s.bytes as usize, s.capacity_or_alloc_ptr, s.length],
            tag: Tag::Utf8 as u8,
        }
    }

    pub fn tag(&self) -> Tag {
        Tag::from_u8(self.tag)
    }

    /// The payload of a list tag.
    pub fn as_list(&self) -> RocList {
        let tag = self.tag();
        assert!(tag != Tag::Absent && tag != Tag::Utf8, "buffer {tag:?} is no list");
        RocList {
            elements: self.payload[0] as *const c_void,
            length: self.payload[1],
            capacity_or_alloc_ptr: self.payload[2],
        }
    }
}

/// `Host.Array`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct HostArray {
    pub length: i64,
    pub null_count: i64,
    pub offset: i64,
    pub buffers: RocList,
    pub children: RocList,
    pub dictionary: RocList,
}

/// `Host.Schema`.
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct HostSchema {
    pub format: RocList,
    pub name: RocList,
    pub metadata: RocList,
    pub flags: i64,
    pub children: RocList,
    pub dictionary: RocList,
}

const _: () = assert!(std::mem::size_of::<HostBuffer>() == 32);
const _: () = assert!(std::mem::size_of::<HostArray>() == 96);
const _: () = assert!(std::mem::size_of::<HostSchema>() == 128);

impl HostArray {
    pub fn buffers(&self) -> &[HostBuffer] {
        unsafe { slice_of(self.buffers) }
    }

    pub fn children(&self) -> &[HostArray] {
        unsafe { slice_of(self.children) }
    }
}

/// The elements of a list that Roc or the host keeps alive.
///
/// # Safety
/// `list` must hold `length` elements of `T`.
pub unsafe fn slice_of<'a, T>(list: RocList) -> &'a [T] {
    if list.length == 0 {
        return &[];
    }
    std::slice::from_raw_parts(list.elements as *const T, list.length)
}

extern "C" {
    fn roc_run(input: HostArray, schema: HostSchema) -> HostArray;
}

/// Call the Roc entry point. The schema name picks the step.
pub fn run(input: HostArray, schema: HostSchema) -> HostArray {
    // SAFETY: both values hold static lists or lists that Roc owns.
    unsafe { roc_run(input, schema) }
}

/// Give a Roc result back to Roc, which frees what it owns.
pub fn drop_value(value: HostArray) {
    let name = b"drop";
    let schema = HostSchema {
        format: static_list(b"n".as_ptr(), 1),
        name: static_list(name.as_ptr(), name.len()),
        metadata: static_list(std::ptr::null::<u8>(), 0),
        flags: 0,
        children: static_list(std::ptr::null::<u8>(), 0),
        dictionary: static_list(std::ptr::null::<u8>(), 0),
    };
    let empty = run(value, schema);
    assert_eq!(empty.length, 0, "drop returns an empty array");
}

// ---------------------------------------------------------------------------
// Static lists: a seamless slice whose allocation word points just past a
// refcount word of 0. Roc never frees or changes such a list. The word is in
// read-only memory, so a write by Roc faults.

static STATIC_RC: [isize; 2] = [0, 0];

#[repr(align(16))]
struct Empty([u8; 16]);
static EMPTY: Empty = Empty([0; 16]);

/// A non-null, 16-byte aligned pointer for an empty buffer.
pub fn empty_ptr() -> *const c_void {
    EMPTY.0.as_ptr() as *const c_void
}

fn static_word() -> usize {
    (&STATIC_RC[1] as *const isize as usize) | 1
}

/// A list of `length` elements at `elements` that Roc never frees.
pub fn static_list<T>(elements: *const T, length: usize) -> RocList {
    let elements = if elements.is_null() || length == 0 {
        empty_ptr()
    } else {
        elements as *const c_void
    };
    RocList {
        elements,
        length,
        capacity_or_alloc_ptr: static_word(),
    }
}

/// A big-form `Str` over host bytes that Roc never frees.
pub fn static_str(bytes: *const u8, length: usize) -> RocStr {
    let bytes = if bytes.is_null() || length == 0 {
        empty_ptr() as *const u8
    } else {
        bytes
    };
    RocStr {
        bytes,
        capacity_or_alloc_ptr: static_word(),
        length,
    }
}

/// Whether a list is a static host list.
pub fn is_static(list: RocList) -> bool {
    list.capacity_or_alloc_ptr == static_word()
}

pub fn static_rc_intact() -> bool {
    STATIC_RC[0] == 0
}

// ---------------------------------------------------------------------------
// Runtime hooks. Each thread counts the blocks Roc holds, so a test can
// check that a case frees all it allocated.

thread_local! {
    static LIVE_BLOCKS: Cell<i64> = const { Cell::new(0) };
    static ALLOCATIONS: Cell<u64> = const { Cell::new(0) };
    static CASE: RefCell<String> = const { RefCell::new(String::new()) };
}

/// The blocks Roc allocated on this thread and did not free.
pub fn live_blocks() -> i64 {
    LIVE_BLOCKS.with(|n| n.get())
}

/// The blocks Roc allocated on this thread so far, a realloc counted as one.
pub fn allocations() -> u64 {
    ALLOCATIONS.with(|n| n.get())
}

/// Name the case this thread runs, for the message of a Roc crash.
pub fn set_case(description: &str) {
    CASE.with(|c| *c.borrow_mut() = description.to_string());
}

/// glibc's `malloc` gives 16-byte aligned blocks; a wider alignment takes
/// `posix_memalign`.
const MALLOC_ALIGN: usize = 16;

#[no_mangle]
pub extern "C" fn roc_alloc(length: usize, alignment: usize) -> *mut c_void {
    let p = if alignment <= MALLOC_ALIGN {
        // SAFETY: plain malloc of at least one byte.
        unsafe { libc::malloc(length.max(1)) }
    } else {
        let mut p: *mut c_void = std::ptr::null_mut();
        // SAFETY: alignment is a power of two and a multiple of the pointer size.
        if unsafe { libc::posix_memalign(&mut p, alignment, length.max(1)) } != 0 {
            p = std::ptr::null_mut();
        }
        p
    };
    if p.is_null() {
        eprintln!("roc_alloc: out of memory");
        std::process::abort();
    }
    LIVE_BLOCKS.with(|n| n.set(n.get() + 1));
    ALLOCATIONS.with(|n| n.set(n.get() + 1));
    p
}

/// # Safety
/// `ptr` is a live block from `roc_alloc`.
#[no_mangle]
pub unsafe extern "C" fn roc_dealloc(ptr: *mut c_void, _alignment: usize) {
    LIVE_BLOCKS.with(|n| n.set(n.get() - 1));
    // SAFETY: Roc frees only what roc_alloc gave it.
    unsafe { libc::free(ptr) }
}

/// Grows in place where `realloc` can; a block of a wider alignment moves.
///
/// # Safety
/// `ptr` is a live block from `roc_alloc`.
#[no_mangle]
pub unsafe extern "C" fn roc_realloc(ptr: *mut c_void, new_length: usize, alignment: usize) -> *mut c_void {
    if alignment <= MALLOC_ALIGN {
        // SAFETY: ptr came from malloc, as its alignment shows.
        let p = unsafe { libc::realloc(ptr, new_length.max(1)) };
        ALLOCATIONS.with(|n| n.set(n.get() + 1));
        if p.is_null() {
            eprintln!("roc_realloc: out of memory");
            std::process::abort();
        }
        return p;
    }
    let fresh = roc_alloc(new_length, alignment);
    // SAFETY: ptr is a live block of at least its usable size.
    unsafe {
        let old = libc::malloc_usable_size(ptr);
        std::ptr::copy_nonoverlapping(ptr as *const u8, fresh as *mut u8, old.min(new_length));
    }
    roc_dealloc(ptr, alignment);
    fresh
}

fn text(bytes: *const u8, len: usize) -> String {
    // SAFETY: Roc passes `len` readable bytes.
    String::from_utf8_lossy(unsafe { std::slice::from_raw_parts(bytes, len) }).into_owned()
}

#[no_mangle]
pub extern "C" fn roc_dbg(bytes: *const u8, len: usize) {
    eprintln!("[roc dbg] {}", text(bytes, len));
}

#[no_mangle]
pub extern "C" fn roc_expect_failed(bytes: *const u8, len: usize) {
    eprintln!("[roc expect] {}", text(bytes, len));
}

/// A crash cannot unwind through Roc frames, so it ends the process. The
/// message names the case that was running.
#[no_mangle]
pub extern "C" fn roc_crashed(bytes: *const u8, len: usize) {
    let case = CASE.with(|c| c.borrow().clone());
    // Straight to stderr: the test harness would hold back an eprintln.
    let _ = writeln!(std::io::stderr(), "Roc crashed: {}\n  case: {case}", text(bytes, len));
    std::process::abort();
}
