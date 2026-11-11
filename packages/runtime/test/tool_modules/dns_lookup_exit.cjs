const {lookup}=require('node:dns/promises');
if(process.argv[2]==='live') lookup('localhost',{all:true,verbatim:true}).then(records=>require('node:fs').writeFileSync(process.argv[3],JSON.stringify(records)));
else lookup('home-ecosystem-repro.invalid',{all:true}).then(()=>{throw new Error('Unexpected real DNS success')});
