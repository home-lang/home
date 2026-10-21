declare module 'pkg' {
  export namespace Nested {
    export class Box {
      constructor(value: 'ready');
      get id(): 1;
      static get own(): 'own';
    }
  }
}
