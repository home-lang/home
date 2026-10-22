declare module 'same-scope' {
  export namespace Api {
    export namespace Derived { export const extra: 3; }
    export namespace Direct { export const flag: 5; }
    export class Base { constructor(value: string); }
    export class Derived extends Base {}
    export class Direct { constructor(); }
  }
}
