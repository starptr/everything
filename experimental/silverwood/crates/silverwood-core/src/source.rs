use std::path::Path;

use crate::error::{Error, Result};

/// An absolute local directory path a code-change is copy-on-write cloned from
/// (the seed of the `apfs-cow` checkout mode). Validated at construction to be
/// absolute; existence, filesystem type, and same-volume are checked later by the
/// forest (they depend on the checkout's target location).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AbsolutePath(String);

impl AbsolutePath {
    /// Parse and validate an absolute path. Relative paths are rejected.
    pub fn parse(input: &str) -> Result<Self> {
        if !Path::new(input).is_absolute() {
            return Err(Error::InvalidSource(format!(
                "{input:?}: path must be absolute"
            )));
        }
        Ok(AbsolutePath(input.to_string()))
    }

    /// The validated path as a string.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// The validated path as a [`Path`].
    pub fn as_path(&self) -> &Path {
        Path::new(&self.0)
    }
}

impl std::fmt::Display for AbsolutePath {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// An HTTPS git endpoint a code-change is cloned from (e.g. a GitHub clone
/// URL). Validated at construction: the scheme must be `https` and a host must
/// be present. Non-HTTPS forms (`ssh://`, `git@…`) are rejected — per
/// `DESIGN.md`, silverwood accepts HTTPS sources only for now.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpsGitUrl(String);

impl HttpsGitUrl {
    /// Parse and validate an HTTPS git endpoint.
    pub fn parse(input: &str) -> Result<Self> {
        let url =
            url::Url::parse(input).map_err(|e| Error::InvalidSource(format!("{input:?}: {e}")))?;
        if url.scheme() != "https" {
            return Err(Error::InvalidSource(format!(
                "{input:?}: scheme must be https, got {:?}",
                url.scheme()
            )));
        }
        if url.host_str().is_none() {
            return Err(Error::InvalidSource(format!("{input:?}: missing host")));
        }
        Ok(HttpsGitUrl(url.to_string()))
    }

    /// The validated URL as a string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl std::fmt::Display for HttpsGitUrl {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_https_github_url() {
        let u = HttpsGitUrl::parse("https://github.com/octocat/Hello-World.git").unwrap();
        assert_eq!(u.as_str(), "https://github.com/octocat/Hello-World.git");
    }

    #[test]
    fn rejects_ssh_and_scp_forms() {
        assert!(HttpsGitUrl::parse("git@github.com:octocat/Hello-World.git").is_err());
        assert!(HttpsGitUrl::parse("ssh://git@github.com/octocat/Hello-World.git").is_err());
    }

    #[test]
    fn rejects_http_and_garbage() {
        assert!(HttpsGitUrl::parse("http://github.com/x/y.git").is_err());
        assert!(HttpsGitUrl::parse("not a url").is_err());
    }

    #[test]
    fn absolute_path_accepts_absolute() {
        let p = AbsolutePath::parse("/Users/x/repo").unwrap();
        assert_eq!(p.as_str(), "/Users/x/repo");
        assert_eq!(p.as_path(), std::path::Path::new("/Users/x/repo"));
    }

    #[test]
    fn absolute_path_rejects_relative() {
        assert!(AbsolutePath::parse("repo").is_err());
        assert!(AbsolutePath::parse("./repo").is_err());
        assert!(AbsolutePath::parse("../repo").is_err());
    }
}
