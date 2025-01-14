//! Extremely minimal logging

use std::{
    cell::RefCell,
    fmt::{self, Write as _},
    io::{self, Write as _},
    str::FromStr,
    sync::atomic::{AtomicU8, Ordering},
};

#[doc(hidden)]
pub static LOG_LEVEL: AtomicU8 = AtomicU8::new(Level::Info as u8);

#[derive(Clone, Copy)]
#[repr(u8)]
pub enum Level {
    Off = 0,
    Info,
    Trace,
}

pub fn set_level(level: Level) {
    LOG_LEVEL.store(level as u8, Ordering::Relaxed)
}

#[inline(always)]
pub fn max_level() -> u8 {
    LOG_LEVEL.load(Ordering::Relaxed)
}

#[inline(always)]
pub fn trace_enabled() -> bool {
    (Level::Trace as u8) <= max_level()
}

// NOTE: using a thread-local buffer with infrequent flushing means log lines
// arrive out-of-order in the presence of multiple threads.
//
// For our purposes this is not a problem. We are almost exclusively
// single-threaded.
thread_local! {
    static BUF: RefCell<String> = const { RefCell::new(String::new()) };
}

#[inline(never)]
pub fn log(args: fmt::Arguments) {
    BUF.with_borrow_mut(|buf| {
        buf.reserve(4096);
        if let Some(s) = args.as_str() {
            buf.push_str(s);
        } else {
            buf.write_fmt(args).unwrap();
        }
        buf.push('\n');

        if buf.len() >= 4096 {
            flush_inner(buf);
        }
    })
}

// NOTE: this will only flush the current thread's log buffer.
#[inline(never)]
pub fn flush() {
    BUF.with_borrow_mut(flush_inner)
}

#[inline(never)]
fn flush_inner(buf: &mut String) {
    if !buf.is_empty() {
        let mut stderr = io::stderr().lock();
        let _ = stderr.write_all(buf.as_bytes());
        let _ = stderr.flush();
        buf.clear();
    }
}

//
// --- impl Level ---
//

impl Level {
    fn as_str(&self) -> &str {
        match self {
            Self::Off => "off",
            Self::Info => "info",
            Self::Trace => "trace",
        }
    }
}

impl FromStr for Level {
    type Err = ();
    fn from_str(s: &str) -> Result<Self, Self::Err> {
        match s {
            "off" => Ok(Self::Off),
            "info" => Ok(Self::Info),
            "trace" => Ok(Self::Trace),
            _ => Err(()),
        }
    }
}

impl fmt::Debug for Level {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

//
// --- macros ---
//

#[doc(hidden)]
#[macro_export]
macro_rules! log {
    // log!(Level::Info, "a {} event", "log");
    ($lvl:expr, $($arg:tt)+) => ({
        if ($lvl as u8) <= $crate::logger::LOG_LEVEL.load(::core::sync::atomic::Ordering::Relaxed) {
            $crate::logger::log(::core::format_args!($($arg)+));
        }
    });
}

#[macro_export]
macro_rules! info {
    ($($arg:tt)+) => ($crate::log!($crate::logger::Level::Info, $($arg)+))
}
#[macro_export]
macro_rules! trace {
    ($($arg:tt)+) => ($crate::log!($crate::logger::Level::Trace, $($arg)+))
}
