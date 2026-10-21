declare module "pkg" {
  export namespace Nested {
    export const enum Mode { One = 1 }
  }
}

declare module "pkg" {
  export namespace Nested {
    export const enum Mode {
      Two = 1 << 1,
      Three = Two + 1,
      Negative = ~0,
      Half = 1 / 2,
      Shifted = 1 << 31,
      Unsigned = -1 >>> 1,
      Remainder = 5 % 2,
      Trailing,
    }
  }
}
