use nargo_core::{logger, time};

fn main() {
    nargo_core::panic::set_hook();

    let args = time!("parse cli args", nargo_metadata::cli::Args::from_env());
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
