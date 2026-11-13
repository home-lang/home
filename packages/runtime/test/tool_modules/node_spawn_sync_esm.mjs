import cp, {spawnSync} from 'node:child_process';
import legacy, {spawnSync as legacySpawn} from 'child_process';
const result = spawnSync('/bin/sh', ['-c', 'printf esm-native'], {encoding:'utf8'});
console.log(JSON.stringify({same:cp===legacy && spawnSync===cp.spawnSync && spawnSync===legacySpawn,status:result.status,stdout:result.stdout,pidPositive:result.pid>0,error:!!result.error}));
