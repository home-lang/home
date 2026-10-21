declare module "cycle" {
  export namespace Nested {
    export const enum Mode { One = Two + 1 }
  }
}

declare module "cycle" {
  export namespace Nested {
    export const enum Mode { Two = One + 1 }
  }
}

declare module "forward" {
  export namespace Nested {
    export const enum Mode { One = Two + 1, Two = 2 }
  }
}

declare module "duplicate" {
  export namespace Nested {
    export const enum Mode { One = 1 }
  }
}

declare module "duplicate" {
  export namespace Nested {
    export const enum Mode { One = 2 }
  }
}
