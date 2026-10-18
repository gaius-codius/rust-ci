//! A fixture crate for rust-ci's own CI: one function, a unit test and a
//! doctest, so every step of the shared workflow has something to run.

/// Counts the words in `text`, split on whitespace.
///
/// ```
/// assert_eq!(fixture::word_count("one two  three"), 3);
/// ```
#[must_use]
pub fn word_count(text: &str) -> usize {
    text.split_whitespace().count()
}

#[cfg(test)]
mod tests {
    use super::word_count;

    #[test]
    fn counts_words_across_runs_of_whitespace() {
        assert_eq!(word_count(""), 0);
        assert_eq!(word_count("  a\tb\nc  "), 3);
    }
}
