const readline = require('node:readline');
if (readline !== require('readline')) throw new Error('readline alias identity');
const writes = [];
const returns = [];
let callbacks = 0;
const stream = {
  write(sequence, callback) {
    if (this !== stream) throw new Error('write receiver');
    writes.push(sequence);
    if (callback) callback(null);
    return writes.length % 2 === 0;
  },
};
function callback(error) {
  if (error !== null) throw new Error('callback error argument');
  callbacks++;
}
returns.push(readline.cursorTo(stream, 0, callback));
returns.push(readline.cursorTo(stream, 4, 2, callback));
returns.push(readline.moveCursor(stream, -2, 3, callback));
returns.push(readline.moveCursor(stream, 1, -1, callback));
for (const direction of [-1, 0, 1]) returns.push(readline.clearLine(stream, direction, callback));
returns.push(readline.clearScreenDown(stream, callback));
const errors = [];
for (const operation of [
  () => readline.cursorTo(stream, NaN),
  () => readline.cursorTo(stream, 0, NaN),
  () => readline.cursorTo(stream, undefined, 1),
  () => readline.cursorTo(stream, 0, 0, null),
  () => readline.moveCursor(stream, 0, 0, 1),
  () => readline.clearLine(stream, 0, {}),
  () => readline.clearScreenDown(stream, false),
]) {
  try {
    operation();
    throw new Error('invalid argument accepted');
  }
  catch (error) { errors.push([error.name, error.code]); }
}
const failure = new Error('real destination error');
try {
  readline.clearLine({ write() { throw failure; } }, 0);
  throw new Error('destination error swallowed');
}
catch (error) { if (error !== failure) throw error; }
const beforeDeferred = callbacks;
returns.push(readline.cursorTo(null, 0, callback));
returns.push(readline.moveCursor(stream, 0, 0, callback));
returns.push(readline.clearLine(undefined, 0, callback));
returns.push(readline.clearScreenDown(null, callback));
if (callbacks !== beforeDeferred) throw new Error('no-output callbacks must be deferred');
process.nextTick(() => {
  console.log(JSON.stringify({ writes, returns, errors, callbacks }));
});
