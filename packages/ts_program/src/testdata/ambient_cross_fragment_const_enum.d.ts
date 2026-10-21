declare module "pkg" {
  export namespace Nested {
    export const enum Mode { One = 1 }
  }
}

declare module "pkg" {
  export namespace Nested {
    export const enum Mode {
      Two = One << 1,
      Three = Mode.Two + 1,
    }
  }
}
