declare module 'same-scope' {
  export namespace Api {
    export class Base { constructor(value: string); }
    export class Derived extends Base {}
    export namespace Derived { export const extra: 3; }
    export class Direct { constructor(); }
    export namespace Direct { export const flag: 5; }
  }
}
