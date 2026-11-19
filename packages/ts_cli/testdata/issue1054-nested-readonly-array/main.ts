import { nested, outer } from "./source";

const mutable: number[][] = nested;
declare function accept(items: number[][]): void;
accept(nested);
const kept: (readonly number[])[] = nested.flat(0);
const stillNested: number[][] = nested.flat(-1);
const outerMutable: number[][] = outer;
