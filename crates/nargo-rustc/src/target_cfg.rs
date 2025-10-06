//! Run `rustc --target=<target> --print cfg` and parse the output.

use std::process::{Command, Stdio};

pub(crate) struct RustcTargetCfg {
    output: String,
}

pub(crate) struct Cfg<'a> {
    key: &'a str,
    value: Option<&'a str>,
}

impl RustcTargetCfg {
    /// Run `rustc --target=<target> --print cfg` and return the output.
    pub(crate) fn collect(target: &str) -> Self {
        let mut cmd = Command::new("rustc");
        cmd.args(["--target", target, "--print", "cfg"]);

        let output = cmd
            .stderr(Stdio::inherit())
            .output()
            .expect("failed to run `rustc`");

        if !output.status.success() {
            let code = output.status.code().unwrap_or(1);
            panic!(
                "`rustc --target {target} --print cfg` exited with non-zero exit code: {code}"
            );
        }

        let output = String::from_utf8(output.stdout)
            .map_err(|_| ())
            .expect("`rustc --print cfg` output is not valid UTF-8");

        Self { output }
    }

    /// Parses the rustc output and returns an iterator over the (cfg, value)
    /// pairs.
    ///
    /// Lines of the form `<cfg>="<value>"` yield `("<cfg>", Some("<value>"))`.
    /// The surrounding quotes are stripped.
    ///
    /// Lines of the form `<cfg>` yield `("<cfg>", None)`.
    fn iter_cfgs(&self) -> impl Iterator<Item = Cfg<'_>> {
        self.output.split('\n').filter_map(|line| {
            if line.is_empty() {
                return None;
            }

            if let Some((key, quoted_value)) = line.split_once('=') {
                let value = strip_quotes(quoted_value).expect("missing quotes");
                Some(Cfg {
                    key,
                    value: Some(value),
                })
            } else {
                Some(Cfg {
                    key: line,
                    value: None,
                })
            }
        })
    }

    /// Parses the rustc output and calls `f(env_key, env_value)` with the
    /// properly encoded environment variables that should be passed to the
    /// `build_script_build` invocation.
    pub(crate) fn env_cfgs(&self, mut f: impl FnMut(&str, &str)) {
        let mut env_key = String::with_capacity(32);
        let mut env_value = String::with_capacity(32);
        let mut cfgs = self.iter_cfgs().peekable();
        while let Some(cfg) = cfgs.next() {
            // cargo:
            // > This cfg is always true and misleading, so avoid setting it.
            // > That is because Cargo queries rustc without any profile
            // > settings.
            if cfg.key == "debug_assertions" {
                continue;
            }
            // we'll set this from the profile
            if cfg.key == "panic" {
                continue;
            }

            env_key.clear();
            cfg.write_env_key(&mut env_key);

            env_value.clear();
            if let Some(value) = cfg.value {
                env_value.push_str(value);

                // for ="<value>" cfgs, we need to lookahead and ','-join
                // following cfgs with the same key

                while let Some(cfg_n) = cfgs.peek() {
                    if cfg_n.key != cfg.key {
                        break;
                    }

                    let value_n = cfgs.next().unwrap().value.unwrap();
                    env_value.push(',');
                    env_value.push_str(value_n);
                }
            }

            // yield
            f(&env_key, &env_value);
        }
    }
}

fn strip_quotes(s: &str) -> Option<&str> {
    s.strip_prefix('\"').and_then(|s2| s2.strip_suffix('\"'))
}

impl Cfg<'_> {
    pub(crate) fn write_env_key(&self, out: &mut String) {
        out.push_str("CARGO_CFG_");
        for c in self.key.chars() {
            out.push(c.to_ascii_uppercase());
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;

    const CFGS_X86_64_LINUX: &str = r#"
debug_assertions
panic="unwind"
target_abi=""
target_arch="x86_64"
target_endian="little"
target_env="gnu"
target_family="unix"
target_feature="fxsr"
target_feature="sse"
target_feature="sse2"
target_has_atomic="16"
target_has_atomic="32"
target_has_atomic="64"
target_has_atomic="8"
target_has_atomic="ptr"
target_os="linux"
target_pointer_width="64"
target_vendor="unknown"
unix
"#;

    #[ignore]
    #[test]
    fn collect() {
        let output = RustcTargetCfg::collect("x86_64-unknown-linux-gnu");
        println!("{}", output.output);

        println!("===\n");

        let output = RustcTargetCfg::collect("aarch64-unknown-linux-gnu");
        println!("{}", output.output);
    }

    #[test]
    fn iter_cfgs() {
        let output = RustcTargetCfg {
            output: CFGS_X86_64_LINUX.to_owned(),
        };
        let actual = output
            .iter_cfgs()
            .map(|cfg| (cfg.key, cfg.value))
            .collect::<Vec<_>>();
        let expected = vec![
            ("debug_assertions", None),
            ("panic", Some("unwind")),
            ("target_abi", Some("")),
            ("target_arch", Some("x86_64")),
            ("target_endian", Some("little")),
            ("target_env", Some("gnu")),
            ("target_family", Some("unix")),
            ("target_feature", Some("fxsr")),
            ("target_feature", Some("sse")),
            ("target_feature", Some("sse2")),
            ("target_has_atomic", Some("16")),
            ("target_has_atomic", Some("32")),
            ("target_has_atomic", Some("64")),
            ("target_has_atomic", Some("8")),
            ("target_has_atomic", Some("ptr")),
            ("target_os", Some("linux")),
            ("target_pointer_width", Some("64")),
            ("target_vendor", Some("unknown")),
            ("unix", None),
        ];
        assert_eq!(actual, expected);
    }

    #[test]
    fn env_cfgs() {
        let output = RustcTargetCfg {
            output: CFGS_X86_64_LINUX.to_owned(),
        };
        let mut actual_owned = Vec::new();
        output.env_cfgs(|key, value| {
            actual_owned.push((key.to_owned(), value.to_owned()))
        });
        let actual = actual_owned
            .iter()
            .map(|(key, value)| (key.as_str(), value.as_str()))
            .collect::<Vec<_>>();

        let expected = vec![
            ("CARGO_CFG_TARGET_ABI", ""),
            ("CARGO_CFG_TARGET_ARCH", "x86_64"),
            ("CARGO_CFG_TARGET_ENDIAN", "little"),
            ("CARGO_CFG_TARGET_ENV", "gnu"),
            ("CARGO_CFG_TARGET_FAMILY", "unix"),
            ("CARGO_CFG_TARGET_FEATURE", "fxsr,sse,sse2"),
            ("CARGO_CFG_TARGET_HAS_ATOMIC", "16,32,64,8,ptr"),
            ("CARGO_CFG_TARGET_OS", "linux"),
            ("CARGO_CFG_TARGET_POINTER_WIDTH", "64"),
            ("CARGO_CFG_TARGET_VENDOR", "unknown"),
            ("CARGO_CFG_UNIX", ""),
        ];

        assert_eq!(actual, expected);
    }
}
