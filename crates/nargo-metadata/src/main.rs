fn main() {
    nargo_core::panic::set_hook();

    let args = match nargo_metadata::cli::Args::from_env() {
        Ok(args) => args,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    };

    args.run();
}
