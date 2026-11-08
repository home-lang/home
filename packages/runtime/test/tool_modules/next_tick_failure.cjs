const mode = process.argv[2];
if (mode === 'invalid') {
  try { process.nextTick(null); }
  catch (error) { console.log(error.name + ' ' + error.code); }
}
else if (mode === 'handled') {
  const error = new Error('callback identity');
  process.on('uncaughtExceptionMonitor', (caught, origin) => {
    if (caught !== error || origin !== 'uncaughtException') throw new Error('monitor identity');
    console.log('monitor');
  });
  process.once('uncaughtException', (caught, origin) => {
    if (caught !== error || origin !== 'uncaughtException') throw new Error('handler identity');
    console.log('handled');
    process.exitCode = 21;
  });
  process.nextTick(() => { throw error; });
  process.nextTick(() => console.log('later'));
}
else {
  process.on('exit', code => {
    console.log('exit ' + code);
    if (mode === 'override') process.exitCode = 23;
    if (mode === 'exit-throw') throw new Error('exit listener failure');
    process.nextTick(() => console.log('must not run during exit'));
  });
  if (mode === 'monitor') process.on('uncaughtExceptionMonitor', () => console.log('monitor'));
  if (mode === 'handler-throw') process.on('uncaughtException', () => { throw new Error('handler failure'); });
  if (mode === 'monitor-throw') process.on('uncaughtExceptionMonitor', () => { throw new Error('monitor failure'); });
  process.nextTick(() => {
    if (mode === 'undefined') throw undefined;
    throw new Error('nextTick callback failure');
  });
  process.nextTick(() => console.log('must not run after fatal callback'));
}
