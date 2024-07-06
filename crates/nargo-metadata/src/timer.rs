use std::time::Instant;

pub struct Timer {
    file: &'static str,
    line: u32,
    label: &'static str,
    start: Instant,
}

impl Timer {
    pub fn new(file: &'static str, line: u32, label: &'static str) -> Self {
        Self {
            file,
            line,
            label,
            start: Instant::now(),
        }
    }
}

impl Drop for Timer {
    fn drop(&mut self) {
        eprintln!(
            "[{}:{}] {}: {:?}",
            self.file,
            self.line,
            self.label,
            self.start.elapsed(),
        );
    }
}

macro_rules! time {
    ($label:expr, $b:block) => {{
        let _timer =
            $crate::timer::Timer::new(::std::file!(), ::std::line!(), $label);
        $b
    }};
    ($label:expr, $e:expr) => {{
        time!($label, { $e })
    }};
    ($b:block) => {{
        time!("block", $b)
    }};
    ($e:expr) => {{
        time!(::std::stringify!($e), { $e })
    }};
}
