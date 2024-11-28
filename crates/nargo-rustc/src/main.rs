use nargo_core::time;

fn main() {
    nargo_core::panic::set_hook();

    match time!("parse cli args", nargo_rustc::cli::Args::from_env()) {
        Ok(args) => time!("run", args.run()),
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    };
}
