use std::time::Instant;

use crate::logger;

pub struct Timer<'a> {
    level: logger::Level,
    label: &'a str,
    start: Instant,
}

impl<'a> Timer<'a> {
    pub fn new(level: logger::Level, label: &'a str) -> Self {
        Self {
            level,
            label,
            start: Instant::now(),
        }
    }
}

impl Drop for Timer<'_> {
    fn drop(&mut self) {
        if (self.level as u8) <= logger::max_level() {
            logger::log(format_args!(
                "{}: {:?}",
                self.label,
                self.start.elapsed()
            ));
        }
    }
}

#[macro_export]
macro_rules! time_inner {
    ($lvl:expr, $label:expr, $b:block $(,)?) => {{
        let _timer = $crate::timer::Timer::new($lvl, $label);
        $b
    }};
    ($lvl:expr, $label:expr, $e:expr $(,)?) => {{ $crate::time_inner!($lvl, $label, { $e }) }};
    ($lvl:expr, $e:expr) => {{ $crate::time_inner!($lvl, ::std::stringify!($e), { $e }) }};
}

#[macro_export]
macro_rules! time {
    ($($arg:tt)+) => ($crate::time_inner!($crate::logger::Level::Trace, $($arg)+))
}
#[macro_export]
macro_rules! info_time {
    ($($arg:tt)+) => ($crate::time_inner!($crate::logger::Level::Info, $($arg)+))
}
