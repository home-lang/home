for (const load of [() => import('./awaited.mjs', {}), () => import('./awaited.mjs?query'), () => import('./awaited.mjs#fragment'), () => import('./data.json')]) {
  let failure;
  try { await load(); } catch (error) { failure = error; }
  if (!failure || failure.code !== 'ERR_HOME_UNSUPPORTED_IMPORT') throw new Error('unsupported dynamic import was accepted');
}
console.log('OK unsupported dynamic import forms remain explicit errors');
