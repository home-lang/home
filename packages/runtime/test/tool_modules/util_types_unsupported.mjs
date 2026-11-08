import { types } from 'node:util';
import direct from 'node:util/types';
if (direct !== types) throw new Error('reference types aliases differ');
for (const name of ['isPromise', 'isProxy']) {
  let error;
  try { types[name]({}); } catch (caught) { error = caught; }
  if (!error || error.code !== 'ERR_HOME_UNSUPPORTED') throw new Error('missing native reference brand support must remain unsupported');
}
console.log('OK explicit unsupported native brand inspection on JSC reference backend');
