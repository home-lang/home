const mode = process.argv[2];
const error = new Error('standalone rejection');
let rejected;
process.on('exit', code => console.log('exit ' + code));
if (mode === 'listener') {
  process.on('unhandledRejection', (reason, promise) => {
    if (reason !== error || promise !== rejected) throw new Error('rejection notification identity');
    console.log('notification identity');
  });
}
if (mode === 'uncaught') {
  process.on('uncaughtExceptionMonitor', (reason, origin) => {
    if (reason !== error || origin !== 'unhandledRejection') throw new Error('rejection monitor identity');
    console.log('monitor');
  });
  process.on('uncaughtException', (reason, origin) => {
    if (reason !== error || origin !== 'unhandledRejection') throw new Error('rejection handler identity');
    console.log('uncaught identity');
    process.exitCode = 21;
  });
}
if (mode === 'wrapped') {
  process.on('uncaughtException', (reason, origin) => {
    if (!(reason instanceof Error) || reason.code !== 'ERR_UNHANDLED_REJECTION' || origin !== 'unhandledRejection') throw new Error('primitive rejection was not wrapped');
    console.log('wrapped rejection');
    process.exitCode = 22;
  });
}
if (mode === 'listener-throw') process.on('unhandledRejection', () => { throw new Error('listener failure'); });
if (mode === 'handler-throw') process.on('uncaughtException', () => { throw new Error('uncaught handler failure'); });
if (mode === 'second') {
  process.once('unhandledRejection', () => {
    console.log('first notification');
    Promise.resolve().then(() => { throw new Error('second rejection'); });
  });
}
if (mode === 'chain') rejected = Promise.resolve().then(() => { throw error; });
else if (mode === 'async') {
  async function rejectAsync() { throw error; }
  rejected = rejectAsync();
}
else rejected = Promise.reject(mode === 'undefined' || mode === 'wrapped' ? undefined : error);
if (mode === 'handled') rejected.catch(reason => {
  if (reason !== error) throw new Error('handled reason identity');
  console.log('handled');
});
if (mode === 'microtask-handled') Promise.resolve().then(() => rejected.catch(() => console.log('microtask handled')));
