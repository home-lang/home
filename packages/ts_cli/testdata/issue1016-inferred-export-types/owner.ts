// Exports whose type the declaration graph cannot write down before
// checking, so the importer takes the checked type.

// Standard-library values cross by name.
export const map = new Map<string, number>();
export const set = new Set([1]);
export const promise = Promise.resolve(1);
export const pattern = /a/g;
export const date = new Date();
export const error = new Error("x");

// Bigint literals and tuples, readonly ones included.
export const big = 5n;
export const negativeBig = -5n;
export const tuple = [1, "a"] as const;

// Functions with an inferred return type, generic and async ones included.
export function identity<T>(x: T) { return x; }
export function add(a: number, b: number) { return a + b; }
export async function later() { return "s"; }
export function pair() { return [1, "a"] as const; }
export function make() { return { k: 1 }; }
export function overload(x: string): string;
export function overload(x: number): number;
export function overload(x: any) { return x; }
export const arrow = () => "s";
export class Box { x = 1 }
export const box = new Box();
