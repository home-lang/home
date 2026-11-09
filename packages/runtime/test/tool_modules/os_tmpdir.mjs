import os, { tmpdir } from 'node:os';
import alias from 'os';
function check(value,message){if(!value)throw new Error(message);}
check(typeof tmpdir==='function' && tmpdir===os.tmpdir && alias===os,'tmpdir aliases');
const keys=['TMPDIR','TMP','TEMP'];
const saved=keys.map(key=>[key,Object.prototype.hasOwnProperty.call(process.env,key),process.env[key]]);
const cases=[
 [{},'/tmp'],
 [{TMPDIR:'',TMP:'',TEMP:''},'/tmp'],
 [{TMPDIR:'/a///',TMP:'/b',TEMP:'/c'},'/a//'],
 [{TMP:'/b/',TEMP:'/c'},'/b'],
 [{TEMP:'/'},'/'],
 [{TMPDIR:'relative/'},'relative'],
 [{TMPDIR:'///'},'//'],
 [{TMPDIR:' /a/ '},' /a/ '],
 [{TMPDIR:'/missing-directory'},'/missing-directory'],
 [{TMPDIR:'',TMP:'',TEMP:'/last/'},'/last'],
 [{TMPDIR:'.'},'.'],
 [{TMPDIR:'../'},'..'],
 [{TMPDIR:'/é/🟢/'},'/é/🟢'],
 [{TMPDIR:'C:\\temp\\'},'C:\\temp\\'],
];
try {
 for(const [env,expected] of cases){for(const key of keys){delete process.env[key];if(key in env)process.env[key]=env[key];}check(tmpdir()===expected,'environment precedence or single trailing slash: '+JSON.stringify(env));}
 process.env.TMPDIR='/changed-again/';check(tmpdir()==='/changed-again','read environment each call');
} finally {for(const [key,exists,value] of saved){delete process.env[key];if(exists)process.env[key]=value;}}
console.log('OK POSIX os.tmpdir '+cases.length+' environment, precedence, lexical and repeated-call cases');
