import vm from 'node:vm';

// These are unavailable capabilities, not successful VM compatibility checks.
const options = [
  {timeout: 10},
  {breakOnSigint: true},
  {cachedData: new Uint8Array()},
  {produceCachedData: true},
  {importModuleDynamically() {}},
  {microtaskMode: 'afterEvaluate'},
  {contextCodeGeneration: {strings: false}},
  {lineOffset: 2},
  {columnOffset: 2},
  {displayErrors: true},
  {unknownProfile: true},
  Object.create({timeout: 10}),
];
globalThis.__vmRefusedSideEffect = 0;
let refused = 0;
for (const option of options) {
  let caught;
  try { vm.runInThisContext('__vmRefusedSideEffect++', option); }
  catch (error) { caught = error; }
  if (!caught || caught.code !== 'ERR_HOME_UNSUPPORTED' || __vmRefusedSideEffect !== 0) throw Error('VM capability was silently accepted');
  refused++;
}
delete globalThis.__vmRefusedSideEffect;
if (refused !== 12) throw Error('VM refusal denominator mismatch');
console.log('VM REFUSAL 12 CHECKS OK');
