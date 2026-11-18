namespace NS {
  export enum Color { Red, Green, Blue }
}
const a: NS.Color.Blue = "x";
const b: NS.Color.Blue | NS.Color.Red = "x";
const c: NS.Color = "x";
const d: NS.Color.Blue = NS.Color.Blue;
const e: NS.Color.Blue = NS.Color.Red;
