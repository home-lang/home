import os, { cpus } from 'node:os';
import { createRequire } from 'node:module';
const requireHere = createRequire(import.meta.url);
const results = [];
function check(label, condition) {
  if (!condition) throw new Error(label);
  results.push(label);
}
check('default and bare module identity', os === requireHere('os'));
check('named export identity', cpus === os.cpus);
check('native callback is private', !Object.prototype.hasOwnProperty.call(globalThis, '__home_tool_cpu_information'));
const first = cpus();
const second = cpus();
check('nonempty processor array', Array.isArray(first) && first.length > 0);
check('native processor count is stable', first.length === second.length);
check('fresh array', first !== second);
check('fresh processor objects', first.every((cpu, i) => cpu !== second[i]));
check('fresh time objects', first.every((cpu, i) => cpu.times !== second[i].times));
check('native model metadata', first.every(cpu => typeof cpu.model === 'string' && cpu.model.length > 0));
check('native MHz or unavailable zero', first.every(cpu => Number.isInteger(cpu.speed) && cpu.speed >= 0));
check('time fields', first.every(cpu => Object.keys(cpu.times).sort().join() === 'idle,irq,nice,sys,user'));
check('nonnegative safe milliseconds', first.every(cpu => Object.values(cpu.times).every(time => Number.isSafeInteger(time) && time >= 0)));
check('actual kernel time counters', first.every(cpu => cpu.times.user + cpu.times.sys + cpu.times.idle > 0));
first[0].model = 'mutated snapshot';
first[0].times.user = -1;
first.push({});
check('mutations do not change another snapshot', second.length + 1 === first.length && second[0].model !== first[0].model && second[0].times.user >= 0);
if (results.length !== 14) throw new Error('incomplete CPU information contract');
console.log('NODE CPU INFORMATION ' + results.length + ' CHECKS OK');
// The parent fixture brackets this fresh snapshot with independent host reads.
console.log(JSON.stringify(cpus()));
