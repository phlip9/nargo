use std::{
    io::{self, Write},
    panic::{Location, PanicInfo},
};

/// Set a small custom panic hook that prints panics to `stderr` before calling
/// `std::process:exit(1)`.
///
/// Does not unwind or print a backtrace.
pub fn set_hook() {
    std::panic::set_hook(Box::new(nargo_panic_hook));
}

fn nargo_panic_hook(panic_info: &PanicInfo<'_>) {
    // Extract message and location from panic.
    let payload = panic_info.payload();
    let message: &str = if let Some(s) = payload.downcast_ref::<&str>() {
        s
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.as_str()
    } else {
        "panic with unknown payload"
    };
    let location = panic_info.location().unwrap_or_else(|| Location::caller());

    // Print panic message to stderr
    let out = format!("\nError: {message}\nLocation: {location}\n");
    let mut stderr = io::stderr().lock();
    let _ = stderr.write_all(out.as_bytes());
    let _ = stderr.flush();

    // Use `exit` instead of `abort` to avoid terminating with SIGABRT and
    // generating lots of core dumps.
    std::process::exit(1);
}
