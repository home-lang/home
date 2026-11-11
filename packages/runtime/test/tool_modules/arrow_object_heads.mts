import './arrow_object_heads.mjs';
let checks=0;
function check(value:boolean){if(!value)throw new Error('Typed arrow object head mismatch');checks++;}
const assertion=()=>({a:1} as {a:number});check(assertion().a===1);
const satisfies=()=>({a:2} satisfies {a:number}).a;check(satisfies()===2);
const nonNull=()=>({a:3})!.a;check(nonNull()===3);
const angle=()=><{a:number}>{a:4};check(angle().a===4);
if(checks!==4)throw new Error('Typed arrow fixture denominator mismatch');
console.log('TYPED ARROW OBJECT HEAD 4 CHECKS OK');
