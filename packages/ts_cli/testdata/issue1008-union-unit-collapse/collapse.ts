enum Shade { Dark = "d", Light = "l" }
enum Color { Red = "r", Green = "g", Blue = "b" }
declare const obj: { q: 1 };
const a: 1 | true | false = obj;
const b: "s" | Shade.Dark | Shade.Light = obj;
const c: true | false = obj;
const d: Color.Red | Color.Green = obj;
const e: Shade.Dark | Shade.Light = obj;
