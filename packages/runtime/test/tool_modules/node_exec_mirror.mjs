import { execFileSync } from 'node:child_process';
const value = execFileSync(process.argv[2], [process.argv[3], 'stderr']);
console.log('DEFAULT CAPTURE STDOUT ' + value.toString('hex'));
