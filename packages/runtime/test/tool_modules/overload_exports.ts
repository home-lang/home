export function defineCommand(factory: () => number): () => number
export function defineCommand<T>(definition: { value: T }): () => T
export function defineCommand(input: any): () => any {
  if (typeof input === 'function') return input;
  return () => input.value;
}
export declare const missing: number;
export declare function ambient(): void;
