// use std::panic;

fn main() {
    // panic::set_hook(Box::new(panic_hook));
    //
    // let foo = "askldfjoasdif".to_owned();
    // panic::panic_any(foo.as_str());

    let args = match nargo_metadata::cli::Args::from_env() {
        Ok(args) => args,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(0);
        }
    };

    args.run();

    // match args.run() {
    //     Ok(()) => (),
    //     Err(err) => {
    //         eprintln!("nargo-metadata: error: {err:#}");
    //         std::process::exit(0);
    //     }
    // }
}

// fn panic_hook(_panic_info: &panic::PanicInfo<'_>) {
//     eprintln!("panic!");
// }
