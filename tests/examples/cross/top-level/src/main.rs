fn main() {
    const FOO: Option<&str> = option_env!("FOO");
    println!("{FOO:?}");
}
