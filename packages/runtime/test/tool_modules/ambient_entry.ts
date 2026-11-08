import * as augmentation from './ambient_augmentation.ts';
if (augmentation.actual !== 42 || 'ExportedGhost' in augmentation
  || 'Ghost' in globalThis || 'ExportedGhost' in globalThis) {
  throw new Error('ambient declaration created a runtime binding');
}
console.log('OK actual ambient augmentation erasure');
