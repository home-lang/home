let checks=0;
function check(value:boolean){if(!value)throw new Error('Compact type closer mismatch');checks++;}
const single=():Array<number>=>[1];check(single()[0]===1);
const nested=():Array<Array<number>>=>[[2]];check(nested()[0][0]===2);
const triple=():Array<Array<Array<number>>>=>[[[3]]];check(triple()[0][0][0]===3);
const four=():Array<Array<Array<Array<number>>>>=>[[[[4]]]];check(four()[0][0][0][0]===4);
const asynchronous=async():Promise<number>=>5;check(await asynchronous()===5);
const typed=true?(n:number):Array<number>=>[n]:null;check(typed!==null&&typed(6)[0]===6);
const multiline=():Array<
number
>=>[7];check(multiline()[0]===7);
const assigned:Array<number>=[8];check(assigned[0]===8);
const assignedNested:Array<Array<number>>=[[9]];check(assignedNested[0][0]===9);
check(9>=8&&!(8>=9));
let shift=16;shift>>=1;check(shift===8&&(16>>2)===4);
let unsigned=-1;unsigned>>>=31;check(unsigned===1&&(16>>>2)===4);
if(checks!==12)throw new Error('Compact type fixture denominator mismatch');
console.log('COMPACT TYPE CLOSER 12 CHECKS OK');
