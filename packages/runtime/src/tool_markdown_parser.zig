//! HTML-only entry points into the owned Markdown renderer. This module's root
//! encompasses the shared renderer's native URL/collection helper imports.
const md = @import("md/root.zig");
pub const Options = md.Options;
pub const renderToHtmlWithOptions = md.renderToHtmlWithOptions;
