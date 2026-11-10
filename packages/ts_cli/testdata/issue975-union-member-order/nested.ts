interface Zed { z: 1 }
interface Alpha { a: 1 }
interface Box<T> { value: T }
enum Color { Red, Green, Blue }
declare const num: 1;
declare function take(p: { claim: "yes" | "no" }): void;

// The same order applies to a union inside another type.
const g1: Box<"zeta" | "alpha"> = num;
const a1: ("zeta" | "alpha")[] = num;
const t1: ["zeta" | "alpha", number] = num;
const fn: (x: "zeta" | "alpha") => "b" | "a" = num;
const o2: { p: Zed | Alpha; q: number[] | string[] } = num;
function ret(): "zeta" | "alpha" { return num; }
const m1: Map<"zeta" | "alpha", Zed | Alpha> = num;
const p1: Promise<"zeta" | "alpha"> = num;
const r1: Readonly<{ k: "zeta" | "alpha" }> = num;
const n1: "zeta" | "alpha" | null | undefined = num;
take(0);
const cl: { claim: "yes" | "no" } = 0;

// Enum members sort by declaration, not by name, wherever the enum is
// declared.
const en: Color.Green | Color.Red = "x";
namespace Scope {
  export enum Tone { Low, Mid, High }
  export const tone: Tone.Mid | Tone.Low = "x";
  void Tone.High;
}
function local() {
  enum Step { One, Two, Three }
  const step: Step.Two | Step.One = "x";
  void [step, Step.Three];
}
void [g1, a1, t1, fn, o2, ret, m1, p1, r1, n1, cl, en, Color.Blue, Scope.tone, local];
export {};
