function check(value, message) { if (!value) throw new Error(message); }
const root = process.argv[2];
const calls = [];
const options = { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' };
let ticked = false;
const slow = Bun.spawn(['/bin/sh', '-c', 'sleep .15; exit 7'], { ...options, onExit(child, code, signal, error) { calls.push([child === slow, code, signal, error]); } });
check(Number.isInteger(slow.pid) && slow.pid > 0, 'real child pid');
check(slow.exitCode === null && slow.signalCode === null, 'initial running state');
setTimeout(() => { ticked = true; check(slow.exitCode === null, 'timer executes before child exit'); }, 5);
check(await slow.exited === 7, 'actual child failure');
check(ticked && slow.exitCode === 7 && slow.signalCode === null, 'nonblocking spawn and state');
await new Promise(resolve => setTimeout(resolve, 20));
check(calls.length === 1 && calls[0][0] && calls[0][1] === 7 && calls[0][2] === null && calls[0][3] === undefined, 'actual onExit once');
const inherited = Bun.spawn(['/bin/sh', '-c', 'read line; test "$line" = "actual inherited input" || exit 41; test "$WITNESS" = "native 🐿" || exit 42; test "$REMOVED" = "" || exit 43; printf "native child stdout 🐿\\n"; printf "native child stderr\\n" >&2; printf "%s" "$PWD" > cwd.txt'], { cwd: root, env: { WITNESS: 'native 🐿', PATH: '/usr/bin:/bin' }, stdio: ['inherit', 'inherit', 'inherit'] });
check(await inherited.exited === 0, 'actual inherited descriptors, env and cwd');
const parallel = [3, 4, 5].map(code => Bun.spawn(['/bin/sh', '-c', `sleep .03; exit ${code}`], options));
check((await Promise.all(parallel.map(child => child.exited))).join(',') === '3,4,5', 'distinct concurrent children');
const tuple = Bun.spawn(['/bin/sh', '-c', 'printf "must be ignored"; exit 11'], { stdio: ['ignore', 'ignore', 'ignore'], stdout: 'pipe' });
check(tuple.stdout === undefined && await tuple.exited === 11, 'stdio tuple precedes the individual stdout option');
const killed = Bun.spawn(['/bin/sh', '-c', 'exec sleep 5'], options);
killed.kill('SIGTERM');
check(await killed.exited === 143 && killed.exitCode === null && killed.signalCode === 'SIGTERM', 'real signal status');
killed.kill();
for (const [argv, config] of [[['/home-tool-no-such-executable'], options], [['/bin/sh', '-c', 'exit 0'], { ...options, cwd: root + '/absent' }]]) {
  let error; try { Bun.spawn(argv, config); } catch (caught) { error = caught; }
  check(error && error.code === 'ENOENT', 'actual spawn error');
}
check(await Bun.spawn(['sh', '-c', 'exit 19'], { ...options, env: { PATH: '/bin' } }).exited === 19, 'child PATH resolution');
console.log('OK real asynchronous child lifecycle');
