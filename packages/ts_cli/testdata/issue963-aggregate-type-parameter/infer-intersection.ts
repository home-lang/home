type Peel<T> = T extends infer U & { x: number } ? U : never;

type A = Peel<{ x: number; y: string }>;
const good: A = { x: 1, y: 'a' };
const bad: A = { x: 1, y: 2 };

type B = Peel<{ x: string }>;
const neverValue: B = { x: 'a' };
void [good, bad, neverValue];
