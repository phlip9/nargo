use nargo_core::logger;

fn main() {
    nargo_core::panic::set_hook();

    let args = nargo_resolve::cli::Args::from_env();
    let args = match args {
        Ok(args) => args,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    };

    args.run();

    logger::flush();
}
