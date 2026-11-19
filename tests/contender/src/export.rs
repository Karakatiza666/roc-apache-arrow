//! Roc to arrow-rs: a `Host.Array` that Roc returned becomes a C
//! `ArrowArray` whose buffers are the Roc lists themselves (zero copy), and
//! arrow-rs imports it with `from_ffi`. The release callback gives the value
//! back to Roc, which frees its lists.

use std::ffi::c_void;

use arrow::array::{make_array, ArrayData, ArrayRef};
use arrow::datatypes::DataType;
use arrow::error::ArrowError;
use arrow::ffi::{from_ffi, FFI_ArrowArray, FFI_ArrowSchema};

use crate::import::{c_sizes, roles, Role};
use crate::roc::{self, empty_ptr, HostArray, Tag};

/// The `struct ArrowArray` of the C Data Interface, with the field order of
/// arrow-rs's `FFI_ArrowArray`.
#[repr(C)]
struct CArray {
    length: i64,
    null_count: i64,
    offset: i64,
    n_buffers: i64,
    n_children: i64,
    buffers: *mut *const c_void,
    children: *mut *mut CArray,
    dictionary: *mut CArray,
    release: Option<unsafe extern "C" fn(*mut CArray)>,
    private_data: *mut c_void,
}

const _: () = assert!(std::mem::size_of::<CArray>() == std::mem::size_of::<FFI_ArrowArray>());

/// What one exported node owns. Only the root holds the Roc value.
struct Private {
    value: Option<HostArray>,
    buffers: Vec<*const c_void>,
    children: Vec<*mut CArray>,
}

/// Free a node and its children. The root also gives its value back to Roc.
unsafe fn free_node(node: *mut CArray) {
    let private = Box::from_raw((*node).private_data as *mut Private);
    for &kid in &private.children {
        free_node(kid);
        drop(Box::from_raw(kid));
    }
    if let Some(value) = private.value {
        roc::drop_value(value);
    }
    (*node).private_data = std::ptr::null_mut();
    (*node).release = None;
}

unsafe extern "C" fn release_root(node: *mut CArray) {
    free_node(node);
}

/// The root frees the children; a consumer never releases a child itself.
unsafe extern "C" fn release_child(node: *mut CArray) {
    (*node).release = None;
}

/// Why an export breaks the C Data Interface.
#[derive(Debug)]
pub struct ExportError(pub String);

/// # Safety
/// `h` is a live Roc value of type `dt`.
unsafe fn node(h: &HostArray, dt: &DataType, root: bool, path: &str) -> Result<*mut CArray, ExportError> {
    let bufs = h.buffers();
    let rs = roles(dt, bufs.len());
    if rs.len() != bufs.len() {
        return Err(ExportError(format!(
            "{path}: {} buffers for {dt}, want {}",
            bufs.len(),
            rs.len()
        )));
    }
    if h.offset < 0 || h.length < 0 {
        return Err(ExportError(format!("{path}: negative length or offset")));
    }
    let mut ptrs = Vec::with_capacity(bufs.len());
    let mut held = Vec::with_capacity(bufs.len());
    for (i, (b, role)) in bufs.iter().zip(&rs).enumerate() {
        let tag = b.tag();
        match tag {
            Tag::Absent => {
                ptrs.push(std::ptr::null());
                held.push(0);
            }
            Tag::Utf8 => return Err(ExportError(format!("{path}: buffer {i} is a Utf8 Str"))),
            _ => {
                let list = b.as_list();
                let p = if list.length == 0 { empty_ptr() } else { list.elements };
                if !(p as usize).is_multiple_of(tag.width()) {
                    return Err(ExportError(format!("{path}: buffer {i} ({tag:?}) is not aligned")));
                }
                if let Role::Values(want) | Role::Offsets(want) = role {
                    if tag != *want && tag != Tag::U8s {
                        return Err(ExportError(format!("{path}: buffer {i} is {tag:?}, want {want:?}")));
                    }
                }
                ptrs.push(p);
                held.push(list.length * tag.width());
            }
        }
    }
    // The importer reads as many bytes as the C sizes say: each list must
    // hold them, or arrow-rs would read past it.
    let rows = (h.length + h.offset) as usize;
    // c_sizes reads the last offset and the view sizes: check those first.
    let n_data = rs.iter().filter(|r| **r == Role::ViewData).count();
    for (i, role) in rs.iter().enumerate() {
        let need = match role {
            Role::Offsets(t) => (rows + 1) * t.width(),
            Role::ViewSizes => n_data * 8,
            _ => continue,
        };
        if held[i] < need {
            return Err(ExportError(format!(
                "{path}: buffer {i} holds {} bytes, need {need}",
                held[i]
            )));
        }
    }
    let want = c_sizes(dt, rows, &ptrs.iter().map(|p| *p as *const u8).collect::<Vec<_>>());
    for (i, (have, need)) in held.iter().zip(&want).enumerate() {
        if !ptrs[i].is_null() && have < need {
            return Err(ExportError(format!(
                "{path}: buffer {i} holds {have} bytes, the C sizes need {need}"
            )));
        }
    }
    let kid_types: Vec<DataType> = match dt {
        DataType::List(f) | DataType::LargeList(f) | DataType::FixedSizeList(f, _) | DataType::Map(f, _) => {
            vec![f.data_type().clone()]
        }
        DataType::Struct(fs) => fs.iter().map(|f| f.data_type().clone()).collect(),
        _ => vec![],
    };
    let hkids = h.children();
    if hkids.len() != kid_types.len() {
        return Err(ExportError(format!(
            "{path}: {} children, want {}",
            hkids.len(),
            kid_types.len()
        )));
    }
    let mut children = Vec::with_capacity(hkids.len());
    for (i, (k, kdt)) in hkids.iter().zip(&kid_types).enumerate() {
        children.push(node(k, kdt, false, &format!("{path}.{i}"))?);
    }
    let mut private = Box::new(Private {
        value: if root { Some(*h) } else { None },
        buffers: ptrs,
        children,
    });
    let out = CArray {
        length: h.length,
        null_count: h.null_count,
        offset: h.offset,
        n_buffers: private.buffers.len() as i64,
        n_children: private.children.len() as i64,
        buffers: private.buffers.as_mut_ptr(),
        children: private.children.as_mut_ptr(),
        dictionary: std::ptr::null_mut(),
        release: Some(if root { release_root } else { release_child }),
        private_data: std::ptr::null_mut(),
    };
    let boxed = Box::into_raw(Box::new(out));
    (*boxed).private_data = Box::into_raw(private) as *mut c_void;
    Ok(boxed)
}

/// Import a Roc result as an arrow-rs array of type `dt` through
/// `from_ffi`. The value goes back to Roc when arrow-rs drops the last
/// buffer. An export that breaks the C Data Interface is an error, and Roc
/// frees the value at once.
pub fn to_arrow(value: HostArray, dt: &DataType) -> Result<ArrayData, ArrowError> {
    let schema = FFI_ArrowSchema::try_from(dt)?;
    // SAFETY: value is a live Roc result of type dt.
    let root = match unsafe { node(&value, dt, true, "root") } {
        Ok(root) => root,
        Err(ExportError(why)) => {
            roc::drop_value(value);
            return Err(ArrowError::CDataInterface(format!("Roc export: {why}")));
        }
    };
    // SAFETY: root is a C ArrowArray with the layout of FFI_ArrowArray;
    // from_raw moves it out and leaves a released struct behind.
    unsafe {
        let ffi = FFI_ArrowArray::from_raw(root as *mut FFI_ArrowArray);
        drop(Box::from_raw(root));
        from_ffi(ffi, &schema)
    }
}

/// `to_arrow`, then `validate_full`, as an array.
pub fn to_arrow_checked(value: HostArray, dt: &DataType) -> Result<ArrayRef, ArrowError> {
    let data = to_arrow(value, dt)?;
    data.validate_full()?;
    Ok(make_array(data))
}

/// Import a C array with no children from its parts through `from_ffi`,
/// then `validate_full`: what arrow-rs makes of a C producer's buffers,
/// NULL pointers included.
///
/// # Safety
/// Each non-null pointer holds the bytes the C sizes of `dt` need.
pub unsafe fn from_c_parts(
    dt: &DataType,
    length: i64,
    null_count: i64,
    buffers: Vec<*const c_void>,
) -> Result<ArrayData, ArrowError> {
    let schema = FFI_ArrowSchema::try_from(dt)?;
    let mut private = Box::new(Private {
        value: None,
        buffers,
        children: vec![],
    });
    let c = CArray {
        length,
        null_count,
        offset: 0,
        n_buffers: private.buffers.len() as i64,
        n_children: 0,
        buffers: private.buffers.as_mut_ptr(),
        children: std::ptr::null_mut(),
        dictionary: std::ptr::null_mut(),
        release: Some(release_root),
        private_data: std::ptr::null_mut(),
    };
    let boxed = Box::into_raw(Box::new(c));
    (*boxed).private_data = Box::into_raw(private) as *mut c_void;
    let ffi = FFI_ArrowArray::from_raw(boxed as *mut FFI_ArrowArray);
    drop(Box::from_raw(boxed));
    let data = from_ffi(ffi, &schema)?;
    data.validate_full()?;
    Ok(data)
}
