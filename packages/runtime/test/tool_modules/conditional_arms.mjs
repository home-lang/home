let checks=0;
function check(value){if(!value)throw new Error('Conditional arm mismatch at '+checks);checks++;}
const flag=true,value=[2],object={key:3};let calls=0;
function compute(){calls++;return 4;}
const member=flag?(object.key):undefined
if(member){check(member===3);}
const call=flag?(compute()):undefined
if(call){check(call===4&&calls===1);}
const nested=flag?(Array.isArray(value)?value:[value]):undefined
if(nested){check(nested===value);}
const arithmetic=flag?(object.key+1):undefined
if(arithmetic){check(arithmetic===4);}
const element=flag?(value[0]):undefined
if(element){check(element===2);}
const array=flag?([...value]):undefined
if(array){check(array!==value&&array[0]===2);}
let count=0;const previous=flag?(count++):undefined
if(previous===0){check(count===1);}
let assigned=0;const assignment=flag?(assigned=5):undefined
if(assignment){check(assigned===5&&assignment===5);}
const comparison=flag?(object.key<4):undefined
if(comparison){check(comparison===true);}
const literal=flag?({key:6}.key):undefined
if(literal){check(literal===6);}
const fallback=flag?(object.missing??7):undefined
if(fallback){check(fallback===7);}
let effects=0;const absent=false?((()=>{effects++;return 1;})()):undefined
if(absent===undefined){check(effects===0);}
const beforeWhile=flag?(object.key):undefined
while(true){check(beforeWhile===3);break;}
const beforeFor=flag?(compute()):undefined
for(let i=0;i<1;i++){check(beforeFor===4&&calls===2);}
const beforeTry=flag?(object.key):undefined
try{check(beforeTry===3);}catch(error){throw error;}
const beforeBlock=flag?(object.key):undefined
{check(beforeBlock===3);}
function middleware(options){let currentGroupMiddleware=[];
  const middlewareList = options.middleware
    ? (Array.isArray(options.middleware) ? options.middleware : [options.middleware])
    : undefined
  if (middlewareList) {
    currentGroupMiddleware = [...currentGroupMiddleware, ...middlewareList]
  }
  return currentGroupMiddleware;
}
check(middleware({middleware:'auth'}).join(',')==='auth'&&middleware({}).length===0);
check(middleware({middleware:['auth','log']}).join(',')==='auth,log');
if(checks!==18)throw new Error('Conditional fixture denominator mismatch');
console.log('CONDITIONAL ARM 18 CHECKS OK');
