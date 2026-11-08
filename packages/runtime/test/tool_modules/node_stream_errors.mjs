import { Readable, Writable, Transform } from 'node:stream';
import { pipeline, finished } from 'node:stream/promises';
const results = {};
const argumentErrors = [];
for (const operation of [
  () => new Writable({ highWaterMark: -1 }),
  () => new Readable({ highWaterMark: 0.5 }),
  () => new Writable({ write(chunk, encoding, callback) { callback(); } }).write(null),
  () => new Writable({ write(chunk, encoding, callback) { callback(); } }).write({}),
]) {
  try { operation(); throw new Error('invalid argument accepted'); }
  catch (error) { argumentErrors.push([error.name, error.code]); }
}
results.arguments = argumentErrors;
const failure = new Error('write failed');
const callbacks = [];
const sink = new Writable({ write(chunk, encoding, callback) { process.nextTick(() => callback(failure)); } });
const completion = finished(sink).catch(error => error);
sink.write('first', function(error) { 'use strict'; if (this !== undefined) throw new Error('write callback receiver'); callbacks.push(['first', error === failure]); });
sink.write('second', function(error) { 'use strict'; if (this !== undefined) throw new Error('queued callback receiver'); callbacks.push(['second', error === failure]); });
sink.end(error => callbacks.push(['end', error === failure]));
const caught = await completion;
await new Promise(resolve => process.nextTick(resolve));
if (caught !== failure) throw new Error('write error identity');
results.callbacks = callbacks;

const sync = new Writable({ write(chunk, encoding, callback) { callback(failure); } });
const syncDone = finished(sync).catch(error => error);
const firstAccepted = sync.write('first');
const secondAccepted = sync.write('second');
results.syncError = [firstAccepted, secondAccepted, sync.errored === failure, sync.writable];
if ((await syncDone) !== failure) throw new Error('synchronous write error identity');

const endCallbacks = [];
const ended = new Writable({ write(chunk, encoding, callback) { callback(); } });
const endedCompletion = finished(ended).catch(error => error);
ended.end('first', error => endCallbacks.push(error && error.code));
const accepted = ended.write('late', error => endCallbacks.push(error && error.code));
const endedError = await endedCompletion;
await new Promise(resolve => process.nextTick(resolve));
results.afterEnd = [accepted, endedError.code, endCallbacks];

const multiple = new Writable({ write(chunk, encoding, callback) { callback(); callback(); } });
const multipleCompletion = finished(multiple).catch(error => error);
multiple.end('twice');
results.multiple = (await multipleCompletion).code;

for (const where of ['default-read', 'default-write', 'default-transform']) {
  const input = where === 'default-read' ? new Readable() : Readable.from([Buffer.from('x')]);
  const output = where === 'default-write' ? new Writable() : new Writable({ write(chunk, encoding, callback) { callback(); } });
  let error;
  try {
    if (where === 'default-transform') await pipeline(input, new Transform(), output);
    else await pipeline(input, output);
  }
  catch (failure) { error = failure; }
  if (!error || error.code !== 'ERR_METHOD_NOT_IMPLEMENTED') throw new Error(where + ' must fail');
}
results.abstract = 'ERR_METHOD_NOT_IMPLEMENTED';

const eof = new Readable({ read() {} });
const eofDone = finished(eof).catch(error => error);
eof.push(null);
eof.push(Buffer.from('late'));
results.afterEof = (await eofDone).code;

const cleans = new Writable({ write(chunk, encoding, callback) { callback(); } });
const cleanDone = finished(cleans, { cleanup: true });
cleans.end();
await cleanDone;
results.listeners = ['error', 'close', 'finish', 'end'].map(name => cleans.listenerCount(name));
console.log(JSON.stringify(results));
