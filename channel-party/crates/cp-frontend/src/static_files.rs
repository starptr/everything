//! Serving the static Astro build (the type-agnostic outline: nav, channel tree, layout). Unknown
//! paths fall back to `index.html` so client-side island routing works. See DESIGN §9/§11.

use std::path::Path;

use tower_http::services::{ServeDir, ServeFile};

/// A `ServeDir` over the Astro build directory, falling back to `index.html` (served with 200, so
/// client-side island routing works). §9/§11.
pub fn service(web_dir: &Path) -> ServeDir<ServeFile> {
    ServeDir::new(web_dir).fallback(ServeFile::new(web_dir.join("index.html")))
}
