fn main() {
    let args = match nargo_resolve::cli::Args::from_env() {
        Ok(args) => args,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(0);
        }
    };

    args.run();
}
