const cp = require('node:child_process');
const fs = require('node:fs');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const result = cp.spawnSync(config.python, [config.helper, config.witness, 'limit'], {maxBuffer:128});
console.log(JSON.stringify({pid:result.pid,status:result.status,signal:result.signal,error:result.error && result.error.code,errno:result.error && result.error.errno,bytes:result.stdout && result.stdout.length,aliases:result.output && result.output[1]===result.stdout && result.output[2]===result.stderr}));
