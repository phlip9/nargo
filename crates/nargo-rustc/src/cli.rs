// a

// Goals:
// 1. Keep each individual crate build .drv as small as possible
//    -> Try to precompute, preaggregate, and amortize as much as possible
//    -> pass common parameters as file? If some params are shared between all
//       normal crates or build crates, then we can package them up into a file
//       and just pass the one file to all crate drvs
//    -> what is the threshold for pass inline vs pass as file? 128 B?

// Plan:
//
// -> precompute base "build" and "normal" profile

const HELP: &str = r#"
nargo-rustc

USAGE:
  nargo-rustc [OPTIONS]
"#;

pub struct Args<'a> {
    target_name: &'a str,
}
