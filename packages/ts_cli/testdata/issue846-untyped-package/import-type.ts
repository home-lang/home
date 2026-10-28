import type { box } from 'untyped-esm';

type ImportedModule = typeof import('untyped-esm');
const count: number = (null as unknown as ImportedModule['box']).count;
void count;
