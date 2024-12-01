//! Escape characters that may have special meaning in a POSIX shell.
//!
//! NOTE(phlip9): mostly vendored from the `shell-escape` crate.

use std::borrow::Cow;

/// Escape characters that may have special meaning in a POSIX shell.
pub(crate) fn escape(s: &str) -> Cow<str> {
    if !s.is_empty() && !s.contains(non_whitelisted) {
        return Cow::Borrowed(s);
    }

    let mut es = String::with_capacity(s.len() + 2);
    es.push('\'');
    for ch in s.chars() {
        match ch {
            '\'' | '!' => {
                es.push_str("'\\");
                es.push(ch);
                es.push('\'');
            }
            _ => es.push(ch),
        }
    }
    es.push('\'');
    Cow::Owned(es)
}

fn non_whitelisted(ch: char) -> bool {
    !matches!(
        ch,
        'a'..='z'
        | 'A'..='Z'
        | '0'..='9'
        | '-'
        | '_'
        | '='
        | '/'
        | ','
        | '.'
        | '+'
    )
}

#[cfg(test)]
mod test {
    use super::*;

    #[test]
    fn test_escape() {
        assert_eq!(
            escape("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=/,.+"),
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_=/,.+"
        );
        assert_eq!(escape("--aaa=bbb-ccc"), "--aaa=bbb-ccc");
        assert_eq!(
            escape("linker=gcc -L/foo -Wl,bar"),
            r#"'linker=gcc -L/foo -Wl,bar'"#
        );
        assert_eq!(
            escape(r#"--features="default""#),
            r#"'--features="default"'"#
        );
        assert_eq!(escape(r#"'!\$`\\\n "#), r#"''\'''\!'\$`\\\n '"#);
        assert_eq!(escape(""), r#"''"#);
    }
}
