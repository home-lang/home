import type { U, V, W, X } from "./owner";

declare const invalid: { q: 1 };
const namedU: U = invalid;
const namedV: V = invalid;
const bare: "a" | "b" = invalid;
const throughU: W = invalid;
const throughV: X = invalid;

declare const fromU: U;
declare const fromV: V;
declare const fromBare: "a" | "b";
const toV: V = fromU;
const toU: U = fromV;
const toBare: "a" | "b" = fromU;
const bareToU: U = fromBare;
