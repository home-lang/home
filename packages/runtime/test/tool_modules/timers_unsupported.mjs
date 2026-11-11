import timers from 'node:timers';
import { setTimeout as delay } from 'node:timers/promises';
function check(value, message) { if (!value) throw new Error(message); }
for (const key of ['setImmediate', 'clearImmediate']) check(typeof timers[key] === 'function' && globalThis[key] === timers[key], 'owned immediate export: ' + key);
for (const options of [{ signal: {} }, { unknown: true }]) {
  let reason;
  try { await delay(1, null, options); } catch (error) { reason = error; }
  check(reason && reason.code === 'ERR_HOME_UNSUPPORTED', 'explicitly refused unsupported timer options');
}
console.log('OK owned immediate exports and unsupported timer signal APIs remain explicit');
