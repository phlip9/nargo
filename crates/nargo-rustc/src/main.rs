use nargo_core::time;

use nargo_rustc::cli;

fn main() {
    nargo_core::panic::set_hook();

    let args_raw = time!("read envs", cli::ArgsRaw::from_env());

    // SAFETY: `std::env::remove_var` is not thread-safe. Since we do this early
    // in `main` before spawning any threads, this is ok.
    time!("remove envs", unsafe { cli::ArgsRaw::remove_nargo_envs() });

    let args = time!("parse args", cli::Args::from_raw(&args_raw));

    time!("run", args.run());
}
