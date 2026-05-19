// Copied from bun/src/css/properties/svg.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Strategy A: route the `css` import at `css_parser_stub.zig`. Every
// shape (`SVGPaint`, `SVGPaintFallback`, `StrokeDasharray`, `Marker`)
// references `css_values.{length,color,url}` types that all exist in
// the stub today. The five enum-property aliases
// (`StrokeLinecap`, `StrokeLinejoin`, `ColorInterpolation`,
// `ColorRendering`, `ShapeRendering`, `TextRendering`,
// `ImageRendering`) feed `css.todo_stuff.depth` into the stub's
// `DefineEnumProperty`, matching upstream's parked-on-syntax shape.
// No JSC bridge.

pub const css = @import("../css_parser_stub.zig");

const LengthPercentage = css.css_values.length.LengthPercentage;
const CssColor = css.css_values.color.CssColor;
const Url = css.css_values.url.Url;

/// An SVG [`<paint>`](https://www.w3.org/TR/SVG2/painting.html#SpecifyingPaint) value
/// used in the `fill` and `stroke` properties.
const SVGPaint = union(enum) {
    /// A URL reference to a paint server element, e.g. `linearGradient`, `radialGradient`, and `pattern`.
    Url: struct {
        /// The url of the paint server.
        url: Url,
        /// A fallback to be used in case the paint server cannot be resolved.
        fallback: ?SVGPaintFallback,
    },
    /// A solid color paint.
    Color: CssColor,
    /// Use the paint value of fill from a context element.
    ContextFill,
    /// Use the paint value of stroke from a context element.
    ContextStroke,
    /// No paint.
    None,
};

/// A fallback for an SVG paint in case a paint server `url()` cannot be resolved.
///
/// See [SVGPaint](SVGPaint).
const SVGPaintFallback = union(enum) {
    /// No fallback.
    None,
    /// A solid color.
    Color: CssColor,
};

/// A value for the [stroke-linecap](https://www.w3.org/TR/SVG2/painting.html#LineCaps) property.
pub const StrokeLinecap = css.DefineEnumProperty(css.todo_stuff.depth);

/// A value for the [stroke-linejoin](https://www.w3.org/TR/SVG2/painting.html#LineJoin) property.
pub const StrokeLinejoin = css.DefineEnumProperty(css.todo_stuff.depth);

/// A value for the [stroke-dasharray](https://www.w3.org/TR/SVG2/painting.html#StrokeDashing) property.
const StrokeDasharray = union(enum) {
    /// No dashing is used.
    None,
    /// Specifies a dashing pattern to use.
    Values: ArrayList(LengthPercentage),
};

/// A value for the [marker](https://www.w3.org/TR/SVG2/painting.html#VertexMarkerProperties) properties.
const Marker = union(enum) {
    /// No marker.
    None,
    /// A url reference to a `<marker>` element.
    Url: Url,
};

/// A value for the [color-interpolation](https://www.w3.org/TR/SVG2/painting.html#ColorInterpolation) property.
pub const ColorInterpolation = css.DefineEnumProperty(css.todo_stuff.depth);

/// A value for the [color-rendering](https://www.w3.org/TR/SVG2/painting.html#ColorRendering) property.
pub const ColorRendering = css.DefineEnumProperty(css.todo_stuff.depth);

/// A value for the [shape-rendering](https://www.w3.org/TR/SVG2/painting.html#ShapeRendering) property.
pub const ShapeRendering = css.DefineEnumProperty(css.todo_stuff.depth);

/// A value for the [text-rendering](https://www.w3.org/TR/SVG2/painting.html#TextRendering) property.
pub const TextRendering = css.DefineEnumProperty(css.todo_stuff.depth);

/// A value for the [image-rendering](https://www.w3.org/TR/SVG2/painting.html#ImageRendering) property.
pub const ImageRendering = css.DefineEnumProperty(css.todo_stuff.depth);

const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;

test "css.svg.SVGPaint tags compose into the union" {
    // `SVGPaint.ContextFill` / `.None` are zero-payload tags; verify the
    // tag discriminant lines up. The non-trivial arms (Url, Color) keep
    // the upstream nested-struct shape — `Url.fallback` is `?SVGPaintFallback`.
    const none: SVGPaint = .None;
    const ctx_fill: SVGPaint = .ContextFill;
    const ctx_stroke: SVGPaint = .ContextStroke;
    try std.testing.expect(@as(std.meta.Tag(SVGPaint), none) == .None);
    try std.testing.expect(@as(std.meta.Tag(SVGPaint), ctx_fill) == .ContextFill);
    try std.testing.expect(@as(std.meta.Tag(SVGPaint), ctx_stroke) == .ContextStroke);
}

test "css.svg.Marker.None is selectable" {
    const m: Marker = .None;
    try std.testing.expect(@as(std.meta.Tag(Marker), m) == .None);
}

test "css.svg.StrokeDasharray.None tag" {
    const d: StrokeDasharray = .None;
    try std.testing.expect(@as(std.meta.Tag(StrokeDasharray), d) == .None);
}
