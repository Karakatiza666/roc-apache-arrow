//! Build `app.roc` as a static archive on the test platform and link it.
//!
//! `ROC` names the roc binary (default: `roc` on the PATH; scripts/test-contender.sh
//! sets it to the pinned nightly). `ROC_OPT` picks the backend (default dev).

use std::path::PathBuf;
use std::process::Command;

fn main() {
    let here = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());
    let out = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let roc = std::env::var("ROC").unwrap_or_else(|_| "roc".into());
    let opt = std::env::var("ROC_OPT").unwrap_or_else(|_| "dev".into());
    let target = match std::env::var("CARGO_CFG_TARGET_ARCH").unwrap().as_str() {
        "x86_64" => "x64glibc",
        "aarch64" => "arm64glibc",
        other => panic!("the test platform has no target for {other}"),
    };
    for var in ["ROC", "ROC_OPT"] {
        println!("cargo:rerun-if-env-changed={var}");
    }
    println!("cargo:rerun-if-changed={}", here.join("app.roc").display());
    println!("cargo:rerun-if-changed={}", here.join("platform").display());
    println!("cargo:rerun-if-changed={}", here.join("../../package").display());

    let archive = out.join("libcontender_app.a");
    let status = Command::new(&roc)
        .arg("build")
        .arg(format!("--target={target}"))
        .arg(format!("--opt={opt}"))
        .arg(format!("--output={}", archive.display()))
        .arg(here.join("app.roc"))
        .status()
        .unwrap_or_else(|e| {
            panic!("cannot run '{roc}' ({e}); set ROC to the roc binary (scripts/install-roc.sh prints it)")
        });
    assert!(status.success(), "roc build of app.roc failed");

    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=contender_app");
}
