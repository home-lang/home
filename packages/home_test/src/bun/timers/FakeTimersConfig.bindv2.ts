// Copied from Bun (https://github.com/oven-sh/bun) — MIT-licensed.
// Original: src/runtime/test_runner/timers/FakeTimersConfig.bindv2.ts
// See LICENSE.bun.md for full license text.
import * as b from "bindgenv2";

export const FakeTimersConfig = b.dictionary(
  {
    name: "FakeTimersConfig",
    userFacingName: "FakeTimersOptions",
    generateConversionFunction: true,
  },
  {
    now: {
      type: b.RawAny,
      internalName: "now",
    },
  },
);
