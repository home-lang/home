# Native-precision raster compositing

`Image.PixelComposite` composes a borrowed gray/RGB/RGBA 8/16-bit background and
overlay into an independent straight RGBA canvas. It reuses `PixelView` geometry,
precision expansion and sample access. `ApngCompositor` uses the same exact
source-over primitive at full opacity; its previous small integer weights remain
available without a larger intermediate opacity denominator.

```zig
var result = try Image.PixelComposite.copied(allocator, background, overlay,
    .{ .x = -8, .y = 12, .opacity = 32768 }, 64 * 1024 * 1024, .{});
defer result.deinit();
```

The result has the background's dimensions and the greater input precision by
default. Explicit `bits = 8` keeps high bytes; 8-bit inputs expand by replication
when producing 16-bit output. Output endian is explicit (default little).
Signed 32-bit offsets clip safely even at their extrema. Padding is neither
sampled nor written. Read-only inputs may alias each other; output may not alias
either active source span. Invalid options, geometry, limits, spans and overlap
reject before destination writes.

`over` applies straight-alpha source-over, while `source` replaces the clipped
region and multiplies only source alpha. Opacity is the exact integer 0..65535.
The source-over calculation rounds only the final color and alpha, with ties up;
it does not first round effective source alpha. A zero-coverage OVER source
preserves the destination including hidden RGB. SOURCE preserves source hidden
RGB even with zero resulting alpha, matching the APNG source operation.

Samples blend in their encoded space. The core performs no ICC, gamut, transfer
or premultiplication conversion. Consumers must establish compatible source
interpretations before composition. The older 8-bit artistic `Blend`/`Compose`
APIs retain their existing behavior; this checked raster kernel is separately
available for native precision and alpha compositing.

`Plan.init` validates without allocation. `into` writes caller storage and uses
no heap. `copied` allocates exactly one result through the supplied allocator and
returns the existing `PixelView.Owned` owner. The maximum covers tight output
bytes. Cancellation checks run every row and at most 1024 pixels apart; cancelled
caller storage may be partial. Owned jobs discard that partial result and must
join their worker before retiring inputs, context or reservations.

Tests compare every 8-bit alpha pair and sampled 8/16-bit opacity boundary cases
against an independent unexpanded u256 rational Porter-Duff calculation. They
also cover signed clipping, endian/low bits, padding, read aliases, output
quarantine, all owned allocation failures and cancellation. APNG's existing
source/over/disposal reference tests use this same primitive. The public image
package export is exercised separately on the development compiler.
