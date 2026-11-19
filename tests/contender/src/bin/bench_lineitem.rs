//! The lineitem bench: one way of the job over the whole table, timed per
//! pass. scripts/bench-contender.sh runs it once per way and batch size, so
//! each process has its own peak RSS.
//!
//!   bench_lineitem <way> <batch rows> [phase]
//!   bench_lineitem stats
//!
//! way: rust-rows, rust-kernels, roc-checked, roc-trusted, roc-str-checked,
//! roc-str-trusted. phase: host, import, numeric, full (default).
//! `LINEITEM_ROWS` (default 1000000) and `LINEITEM_PASSES` (default 7) set
//! the size of the run. Before it times, the run checks the way's output
//! against the arrow-rs row loop on every batch, then makes one warm-up pass.
//!
//! With `LINEITEM_PROFILE=1` (Linux x86-64), a SIGPROF timer samples the
//! program counter during the timed passes, and the run prints the share of
//! samples per symbol to stderr: a profile for hosts where `perf` is not
//! allowed.
//!
//! Output: one tab-separated line: way, batch rows, phase, rows, input
//! bytes, passes, median, min and max seconds, RSS before the passes and
//! peak RSS during them (KiB), and the heap allocations per pass (Rust's
//! and Roc's together).

use std::alloc::{GlobalAlloc, Layout, System};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use arrow::array::Array;
use contender::lineitem::{batches, check_way, input_bytes, pass, table, Phase, Way};

const SEED: u64 = 0x11E1_7E00;

/// The system allocator with a count of the blocks Rust allocates; Roc
/// counts its own in `contender::roc::allocations`.
struct Counting;

static RUST_ALLOCATIONS: AtomicU64 = AtomicU64::new(0);

// SAFETY: every call goes to System unchanged.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        RUST_ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        unsafe { System.alloc(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        RUST_ALLOCATIONS.fetch_add(1, Ordering::Relaxed);
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

fn allocations() -> u64 {
    RUST_ALLOCATIONS.load(Ordering::Relaxed) + contender::roc::allocations()
}

fn env(name: &str, default: usize) -> usize {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// A field of /proc/self/status in KiB.
fn status_kib(field: &str) -> u64 {
    let status = std::fs::read_to_string("/proc/self/status").unwrap_or_default();
    status
        .lines()
        .find_map(|l| l.strip_prefix(field))
        .and_then(|v| v.trim().trim_end_matches("kB").trim().parse().ok())
        .unwrap_or(0)
}

/// Set the peak RSS (VmHWM) to the RSS now.
fn reset_peak() {
    let _ = std::fs::write("/proc/self/clear_refs", "5");
}

fn stats(rows: usize) {
    let t = table(rows, SEED);
    let ship = t.column_by_name("shipdate").unwrap();
    let ship = arrow::array::AsArray::as_primitive::<arrow::datatypes::Date32Type>(ship.as_ref());
    let kept = ship
        .values()
        .iter()
        .filter(|d| (contender::lineitem::SHIP_FROM..contender::lineitem::SHIP_UNTIL).contains(*d))
        .count();
    let comment = t.column_by_name("comment").unwrap();
    let comment = arrow::array::AsArray::as_string::<i32>(comment.as_ref());
    let texts: Vec<&str> = comment.iter().flatten().collect();
    let world = texts.iter().filter(|s| !s.is_ascii()).count();
    let chars: usize = texts.iter().map(|s| s.trim().chars().count()).sum();
    println!("rows\t{rows}");
    println!("input bytes\t{}", input_bytes(&t.to_data()));
    println!("kept by the date filter\t{:.1}%", 100.0 * kept as f64 / rows as f64);
    println!(
        "NULL comments\t{:.1}%",
        100.0 * comment.null_count() as f64 / rows as f64
    );
    println!("non-ASCII comments\t{:.1}%", 100.0 * world as f64 / texts.len() as f64);
    println!("comment chars (mean)\t{:.1}", chars as f64 / texts.len() as f64);
    println!(
        "comment bytes (mean)\t{:.1}",
        comment.value_data().len() as f64 / texts.len() as f64
    );
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rows = env("LINEITEM_ROWS", 1_000_000);
    if args.first().map(String::as_str) == Some("stats") {
        stats(rows);
        return;
    }
    let usage = "usage: bench_lineitem <rust-rows|rust-kernels|roc-checked|roc-trusted> <batch rows> [host|import|numeric|full]";
    let way = args.first().and_then(|a| Way::parse(a)).expect(usage);
    let size: usize = args.get(1).and_then(|a| a.parse().ok()).expect(usage);
    let phase = match args.get(2).map(String::as_str).unwrap_or("full") {
        "host" => Phase::Host,
        "import" => Phase::Import,
        "numeric" => Phase::Numeric,
        "full" => Phase::Full,
        _ => panic!("{usage}"),
    };
    let passes = env("LINEITEM_PASSES", 7).max(1);

    let bs = {
        let t = table(rows, SEED);
        batches(&t, size)
    };
    let bytes: usize = bs.iter().map(|b| input_bytes(&b.to_data())).sum();
    if let Err(e) = check_way(way, &bs) {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
    pass(way, &bs, phase, false);
    let rss_before = status_kib("VmRSS:");
    reset_peak();
    let profile = std::env::var("LINEITEM_PROFILE").is_ok_and(|v| v == "1");
    if profile {
        sampler::start();
    }
    let allocs_before = allocations();
    let mut times: Vec<Duration> = (0..passes).map(|_| pass(way, &bs, phase, false).0).collect();
    let allocs_per_pass = (allocations() - allocs_before) / passes as u64;
    if profile {
        sampler::report();
    }
    let rss_peak = status_kib("VmHWM:");
    times.sort();
    let secs = |d: Duration| d.as_secs_f64();
    let phase_name = format!("{phase:?}").to_lowercase();
    println!(
        "{}\t{size}\t{phase_name}\t{rows}\t{bytes}\t{passes}\t{:.6}\t{:.6}\t{:.6}\t{rss_before}\t{rss_peak}\t{allocs_per_pass}",
        way.name(),
        secs(times[times.len() / 2]),
        secs(times[0]),
        secs(times[times.len() - 1]),
    );
}

/// A sampling profiler: SIGPROF every 100 us of CPU time records the
/// interrupted program counter; `nm` names the symbol of each sample.
#[cfg(all(target_os = "linux", target_arch = "x86_64"))]
mod sampler {
    use std::collections::HashMap;
    use std::sync::atomic::{AtomicUsize, Ordering};

    const CAPACITY: usize = 1 << 20;
    static SAMPLES: [AtomicUsize; CAPACITY] = [const { AtomicUsize::new(0) }; CAPACITY];
    static COUNT: AtomicUsize = AtomicUsize::new(0);

    extern "C" fn on_prof(_sig: libc::c_int, _info: *mut libc::siginfo_t, ctx: *mut libc::c_void) {
        // SAFETY: the kernel passes a ucontext_t to an SA_SIGINFO handler.
        let pc = unsafe { (*(ctx as *const libc::ucontext_t)).uc_mcontext.gregs[libc::REG_RIP as usize] } as usize;
        let i = COUNT.fetch_add(1, Ordering::Relaxed);
        if i < CAPACITY {
            SAMPLES[i].store(pc, Ordering::Relaxed);
        }
    }

    pub fn start() {
        // SAFETY: installs a handler that only touches atomics, then a timer.
        unsafe {
            let mut act: libc::sigaction = std::mem::zeroed();
            act.sa_sigaction = on_prof as *const () as usize;
            act.sa_flags = libc::SA_SIGINFO | libc::SA_RESTART;
            libc::sigaction(libc::SIGPROF, &act, std::ptr::null_mut());
            let tick = libc::timeval {
                tv_sec: 0,
                tv_usec: 100,
            };
            let timer = libc::itimerval {
                it_interval: tick,
                it_value: tick,
            };
            libc::setitimer(libc::ITIMER_PROF, &timer, std::ptr::null_mut());
        }
    }

    /// The load address of the executable and the end of its last mapping,
    /// from /proc/self/maps.
    fn image(exe: &str) -> (usize, usize) {
        let maps = std::fs::read_to_string("/proc/self/maps").unwrap_or_default();
        let ranges: Vec<(usize, usize)> = maps
            .lines()
            .filter(|l| l.ends_with(exe))
            .filter_map(|l| {
                let (lo, hi) = l.split(' ').next()?.split_once('-')?;
                Some((usize::from_str_radix(lo, 16).ok()?, usize::from_str_radix(hi, 16).ok()?))
            })
            .collect();
        let lo = ranges.iter().map(|r| r.0).min().unwrap_or(0);
        let hi = ranges.iter().map(|r| r.1).max().unwrap_or(0);
        (lo, hi)
    }

    pub fn report() {
        // SAFETY: stops the timer.
        unsafe {
            let off: libc::itimerval = std::mem::zeroed();
            libc::setitimer(libc::ITIMER_PROF, &off, std::ptr::null_mut());
        }
        let n = COUNT.load(Ordering::Relaxed).min(CAPACITY);
        let exe = std::fs::read_link("/proc/self/exe").expect("the executable");
        let exe = exe.to_string_lossy().into_owned();
        let (base, end) = image(&exe);
        let nm = std::process::Command::new("nm")
            .args(["-n", "-C", "--defined-only", &exe])
            .output()
            .expect("nm");
        let mut syms: Vec<(usize, String)> = String::from_utf8_lossy(&nm.stdout)
            .lines()
            .filter_map(|l| {
                let mut parts = l.splitn(3, ' ');
                let addr = usize::from_str_radix(parts.next()?, 16).ok()?;
                let kind = parts.next()?;
                let name = parts.next()?;
                matches!(kind, "t" | "T" | "W" | "w").then(|| (addr, name.to_string()))
            })
            .collect();
        syms.sort();
        let mut by_symbol: HashMap<String, usize> = HashMap::new();
        for s in &SAMPLES[..n] {
            let pc = s.load(Ordering::Relaxed);
            let name = (pc < end)
                .then(|| pc.checked_sub(base))
                .flatten()
                .and_then(|off| match syms.partition_point(|(a, _)| *a <= off) {
                    0 => None,
                    k => Some(syms[k - 1].1.clone()),
                })
                .unwrap_or_else(|| "(shared libraries: libc malloc, free, memcpy)".to_string());
            *by_symbol.entry(name).or_default() += 1;
        }
        let mut rows: Vec<(usize, String)> = by_symbol.into_iter().map(|(k, v)| (v, k)).collect();
        rows.sort_by(|a, b| b.cmp(a));
        eprintln!("samples\t{n}");
        for (count, name) in rows.iter().take(30) {
            let short: String = name.chars().take(110).collect();
            eprintln!("{:5.1}%\t{short}", 100.0 * *count as f64 / n.max(1) as f64);
        }
    }
}

#[cfg(not(all(target_os = "linux", target_arch = "x86_64")))]
mod sampler {
    pub fn start() {
        eprintln!("LINEITEM_PROFILE needs Linux x86-64");
    }
    pub fn report() {}
}
