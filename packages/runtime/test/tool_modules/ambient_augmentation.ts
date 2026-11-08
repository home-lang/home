import type { Model } from './ambient_registry.ts';

declare module './ambient_registry.ts' {
  interface Model { readonly label?: string }
}
declare namespace Ghost {
  const marker: number
}
export declare namespace ExportedGhost {
  const marker: number
}
const model: Model = { id: 42, label: 'actual augmentation' };
export const actual = model.id;
