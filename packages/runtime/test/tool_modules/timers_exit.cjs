const mode = process.argv[2];
const reason = { timer: true };
if (mode === 'unref') {
  setTimeout(() => console.log('ERROR unreferenced timer fired'), 30).unref();
  console.log('registered unreferenced');
}
else if (mode === 'unref-live') {
  setTimeout(() => console.log('unreferenced fired'), 5).unref();
  setTimeout(() => console.log('referenced fired'), 30);
}
else if (mode === 'clear-ref') {
  const handle = setTimeout(() => console.log('ERROR cleared timer fired'), 1);
  clearTimeout(handle);
  if (!handle.hasRef()) throw new Error('Node retains reference state after cancellation');
  console.log('cleared reference state');
}
else {
  process.on('exit', code => console.log('exit ' + code));
  if (mode === 'handled') {
    process.on('uncaughtExceptionMonitor', (error, origin) => {
      if (error !== reason || origin !== 'uncaughtException') throw new Error('timer monitor identity');
      console.log('monitor');
    });
    process.on('uncaughtException', (error, origin) => {
      if (error !== reason || origin !== 'uncaughtException') throw new Error('timer handler identity');
      console.log('handled identity');
      process.exitCode = 23;
    });
    setTimeout(() => console.log('later timer'), 20);
  }
  if (mode === 'handler-throw') process.on('uncaughtException', () => { throw new Error('handler failure'); });
  if (mode === 'reject-listener') process.on('unhandledRejection', error => {
    if (error !== reason) throw new Error('timer rejection identity');
    console.log('rejected identity');
  });
  setTimeout(() => {
    if (mode === 'reject' || mode === 'reject-listener') Promise.reject(reason);
    else throw reason;
  }, 2);
}
