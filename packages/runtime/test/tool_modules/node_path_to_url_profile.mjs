import { pathToFileURL } from 'node:url';
for (const options of [null, {}, { windows: true }, { windows: false }, false, []]) {
  let rejected = false;
  try { pathToFileURL('/tmp/file', options); }
  catch (error) { rejected = error.code === 'ERR_HOME_UNSUPPORTED'; }
  if (!rejected) throw new Error('Unsupported file URL options were approximated');
}
console.log('OK Home file URL options remain explicitly unsupported');
