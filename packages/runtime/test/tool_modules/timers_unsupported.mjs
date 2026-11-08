import timers from 'node:timers';
import { setTimeout as delay } from 'node:timers/promises';
function check(value, message) { if (!value) throw new Error(message); }
for (const key of ['setImmediate', 'clearImmediate']) check(timers[key] === undefined && globalThis[key] === undefined, 'unsupported timer: ' + key);
for (const options of [{ signal: {} }, { unknown: true }]) {
  let reason;
  try { await delay(1, null, options); } catch (error) { reason = error; }
  check(reason && reason.code === 'ERR_HOME_UNSUPPORTED', 'explicitly refused unsupported timer options');
}
console.log('OK unsupported timer lifecycle and signal APIs remain explicit');
