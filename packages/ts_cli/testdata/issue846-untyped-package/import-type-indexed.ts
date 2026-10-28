import type { box } from 'untyped-esm';

type ImportedBox = typeof import('untyped-esm')['box'];
const count: number = (null as unknown as ImportedBox).count;
const typed: number = (null as unknown as typeof box).count;
void [count, typed];
