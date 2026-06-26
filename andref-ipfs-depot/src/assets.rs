//! The frontend, compiled into the binary so the container ships nothing but the executable.

pub const INDEX_HTML: &str = include_str!("../assets/index.html");
pub const INVALID_HTML: &str = include_str!("../assets/invalid.html");
pub const APP_CSS: &str = include_str!("../assets/app.css");
pub const APP_JS: &str = include_str!("../assets/app.js");
