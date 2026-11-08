if(!Array.isArray(Bun.argv))throw new Error('missing actual Bun argv');
if(Bun.argv!==process.argv||Bun.argv[1]!==process.argv[1]||Bun.argv[2]!=='first'||Bun.argv[3]!=='second space')throw new Error('argv data');
const first=Bun.argv;first.push('shared');if(process.argv[process.argv.length-1]!=='shared')throw new Error('copied arguments');
process.argv=['different'];if(Bun.argv!==first)throw new Error('argv must retain its initial shared array');
const d=Object.getOwnPropertyDescriptor(Bun,'argv');if(!d.writable||!d.enumerable||d.configurable)throw new Error('argv descriptor');
Bun.argv=['replacement'];if(Bun.argv[0]!=='replacement'||process.argv[0]!=='different')throw new Error('argv reassignment');
console.log('OK actual Bun argv identity and arguments');
