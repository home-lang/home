const cp = require('node:child_process');
const fs = require('node:fs');
const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const result = cp.spawnSync(config.python, [config.helper, config.witness, 'inherit'], {stdio:'inherit',env:{WITNESS:'inherited-env'}});
fs.writeFileSync(config.result, JSON.stringify({pid:result.pid,status:result.status,signal:result.signal,stdout:result.stdout,stderr:result.stderr,aliases:result.output.length===3 && result.output.every(value=>value===null),error:!!result.error}));
