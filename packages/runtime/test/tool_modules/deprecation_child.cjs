const {deprecate}=require('node:util');
const mode=process.argv[2] || 'basic';
if(mode==='trace')process.traceDeprecation=true;
if(mode==='throw')process.throwDeprecation=true;
if(mode==='silent')process.noDeprecation=true;
let warnings=0,calls=0;
process.on('warning',warning=>{
  warnings++;
  console.log('EVENT:'+warning.code+':'+warning.name+':'+warning.message);
  if(mode==='listener-throw'){const error=new Error('owned warning listener fatal');error.code='OWN_FATAL_LISTENER';throw error;}
});
process.on('uncaughtExceptionMonitor',error=>console.log('FATAL_CODE:'+error.code));
if(mode==='removed')process.removeAllListeners('warning');
const wrapped=deprecate(function(value){calls++;console.log('BODY:'+calls);return value+calls;},'owned child warning','OWN_CHILD');
const one=wrapped(4),two=wrapped(6);
console.log('SYNC:'+JSON.stringify({one,two,calls,warnings}));
setImmediate(()=>console.log('LATER:'+warnings));
