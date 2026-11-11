import './conditional_arms.mjs';
let checks=0;const flag=true;
function check(value:boolean){if(!value)throw new Error('Typed conditional arrow mismatch');checks++;}
const typed=flag?(n:number):number=>n+1:null
if(typed){check(typed(2)===3);}
let seed=2;const defaults=flag?(n=seed+=1):number=>n:null
if(defaults){check(defaults()===3&&seed===3);}
const generic=flag?<T>(n:T):T=>n:null
if(generic){check(generic('value')==='value');}
const asynchronous=flag?async(n:number):Promise<number>=>n+2:null
if(asynchronous){check(await asynchronous(4)===6);}
if(checks!==4)throw new Error('Typed conditional denominator mismatch');
console.log('TYPED CONDITIONAL ARROW 4 CHECKS OK');
