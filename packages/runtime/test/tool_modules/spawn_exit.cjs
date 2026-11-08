const fs = require('node:fs');
const mode = process.argv[2];
const path = process.argv[3];
const options = { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' };
if (mode === 'orphan') {
  const child = Bun.spawn(['/bin/sh', '-c', 'exec sleep 5'], options);
  fs.writeFileSync(path, String(child.pid));
  throw new Error('owned child cleanup witness');
}
else if (mode === 'callback') {
  Bun.spawn(['/bin/sh', '-c', 'exit 2'], { ...options, onExit() { throw new Error('native child exit witness'); } });
}
else if (mode === 'no-await') {
  Bun.spawn(['/bin/sh', '-c', 'sleep .03; printf "kept alive" > "$1"', 'sh', path], options);
}
else if (mode === 'refusals') {
  for (const extra of [{ stdout: 'pipe' }, { stdin: 'pipe' }, { detached: true }, { timeout: 100 }, { stdio: ['ignore', 'pipe', 'ignore'] }, { stdio: ['ignore', 'ignore'] }]) {
    let error;
    try { Bun.spawn(['/bin/sh', '-c', 'printf "must not execute" > "$1"', 'sh', path], { ...options, ...extra }); }
    catch (caught) { error = caught; }
    if (!error || error.code !== 'ERR_HOME_UNSUPPORTED' || fs.existsSync(path)) throw new Error('unsupported spawn options must refuse before execution');
  }
  const child = Bun.spawn(['/bin/sh', '-c', 'sleep .03; exit 0'], options);
  let error; try { child.unref(); } catch (caught) { error = caught; }
  if (!error || error.code !== 'ERR_HOME_UNSUPPORTED') throw new Error('unsupported unref contract');
  child.exited.then(code => { if (code !== 0) throw new Error('refused unref lost child'); });
}
else throw new Error('unknown spawn witness');
