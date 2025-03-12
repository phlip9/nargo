fn main() {
    #[cfg(all(
        target_os = "linux",
        target_arch = "x86_64",
        target_env = "gnu"
    ))]
    build_dep::foo();
}
