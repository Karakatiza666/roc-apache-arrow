//! The contender harness: arrow-rs arrays in and out of the Roc test app
//! (`tests/contender/app.roc`) through the Arrow C Data Interface.
//!
//! | Step | API |
//! |------|-----|
//! | arrow-rs array to Roc input | [`HostInput::from_array`] (C sizes) or [`HostInput::from_data`] (true sizes) |
//! | run an entry point | [`HostInput::run`], or [`call`] for one shot |
//! | Roc result to arrow-rs | [`RocResult::into_arrow`] (`from_ffi` and `validate_full`) |
//!
//! The schema name of the input picks the entry point of the app. Add an
//! entry point to the `run` match of `app.roc`, then call it by name.

pub mod check;
pub mod digest;
pub mod export;
pub mod gen;
pub mod import;
pub mod lineitem;
pub mod mutate;
pub mod roc;

use arrow::array::{Array, ArrayData, ArrayRef, AsArray};
use arrow::datatypes::DataType;
use arrow::error::ArrowError;

pub use import::{Feed, HostInput};
pub use roc::HostArray;

/// A value Roc returned. Dropping it gives it back to Roc.
pub struct RocResult(Option<HostArray>);

impl RocResult {
    pub fn new(value: HostArray) -> RocResult {
        RocResult(Some(value))
    }

    /// The value as Roc returned it.
    pub fn host(&self) -> &HostArray {
        self.0.as_ref().expect("a live result")
    }

    /// Import the value as an arrow-rs array of type `dt` with zero copy,
    /// and check it with `validate_full`.
    pub fn into_arrow(mut self, dt: &DataType) -> Result<ArrayRef, ArrowError> {
        export::to_arrow_checked(self.0.take().expect("a live result"), dt)
    }

    /// Import the value as an arrow-rs array of type `dt` with zero copy and
    /// no `validate_full`, as a consumer that trusts its producer does.
    pub fn into_arrow_unvalidated(mut self, dt: &DataType) -> Result<ArrayRef, ArrowError> {
        export::to_arrow(self.0.take().expect("a live result"), dt).map(arrow::array::make_array)
    }

    /// The rows of a Utf8 result.
    pub fn into_strings(self) -> Vec<String> {
        let out = self.into_arrow(&DataType::Utf8).expect("a Utf8 result");
        out.as_string::<i32>()
            .iter()
            .map(|s| s.expect("no NULL row").to_string())
            .collect()
    }
}

impl Drop for RocResult {
    fn drop(&mut self) {
        if let Some(value) = self.0.take() {
            roc::drop_value(value);
        }
    }
}

/// The case count of a random test: `CONTENDER_CASES`, else `default`.
pub fn case_count(default: u64) -> u64 {
    std::env::var("CONTENDER_CASES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(default)
}

/// The base seed of a random test: `CONTENDER_SEED`, else a fixed seed, so
/// a CI run is the same each time.
pub fn base_seed() -> u64 {
    std::env::var("CONTENDER_SEED")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(0x00C0_FFEE)
}

/// Run entry point `entry` on `input` and import the result as type `out`.
pub fn call(entry: &str, input: &dyn Array, feed: Feed, out: &DataType) -> Result<ArrayRef, ArrowError> {
    HostInput::from_array(entry, input, feed).run().into_arrow(out)
}

/// The `identity` entry point: the array read and written again by Roc.
pub fn identity(input: &dyn Array, feed: Feed) -> Result<ArrayRef, ArrowError> {
    call("identity", input, feed, input.data_type())
}

/// The `digest` entry point: one text per row.
pub fn digest(input: &dyn Array, feed: Feed) -> Vec<String> {
    HostInput::from_array("digest", input, feed).run().into_strings()
}

/// The `validate` entry point over the true buffer sizes of `data`, with
/// the host's `null_count` replaced when `null_count` is given: `Ok` when
/// Roc accepts it, else Roc's error.
pub fn validate_data(data: &ArrayData, feed: Feed, null_count: Option<i64>) -> Result<(), String> {
    let mut input = HostInput::from_data("validate", data, feed);
    if let Some(n) = null_count {
        input.array.null_count = n;
    }
    verdict(input)
}

/// The `validate` entry point over an input as a C host passes it.
pub fn validate(input: &dyn Array, feed: Feed) -> Result<(), String> {
    verdict(HostInput::from_array("validate", input, feed))
}

fn verdict(input: HostInput) -> Result<(), String> {
    let rows = input.run().into_strings();
    match rows.as_slice() {
        [one] if one == "accept" => Ok(()),
        [one] => Err(one.clone()),
        _ => panic!("validate gives one row, not {rows:?}"),
    }
}
