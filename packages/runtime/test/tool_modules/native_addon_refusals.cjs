// Format refusal checks, not a native-addon implementation or execution score.
const mode=process.argv[2];
const allowed=mode==='home'?['ERR_HOME_UNSUPPORTED_NATIVE_ADDON']:['ERR_DLOPEN_FAILED','ERR_UNKNOWN_FILE_EXTENSION'];
globalThis.__addonSourceExecuted=0;
globalThis.__sourceControlExecuted=0;
const routes=['./text.node','./binary.node','./text','./indexpkg','./mainpkg','addon-pkg','./alias.js','./text.node'];
async function main(){
  const outcomes=[];let resolved=0,refused=0,uncached=0;
  for(const route of routes){
    let filename,error,value;
    try{filename=require.resolve(route);resolved++;value=require(route);}catch(caught){error=caught;}
    const clean=filename!==undefined && require.cache[filename]===undefined;
    if(clean)uncached++;
    if(error && allowed.includes(error.code))refused++;
    outcomes.push({route,path:filename,code:error&&error.code,loaded:value!==undefined,uncached:clean});
  }
  let dynamic;
  try{await import('./static.mjs');}catch(error){dynamic=error;}
  let missing;
  try{require.resolve('./missing.node');}catch(error){missing=error;}
  const source=require('./control.js'),json=require('./control.json');
  const summary={mode,resolved,refused,uncached,sourceBodiesExecuted:__addonSourceExecuted,staticBodyExecuted:globalThis.__staticAddonBody===true,dynamicCode:dynamic&&dynamic.code,missingCode:missing&&missing.code,sourceControls:source===41&&json.answer===42&&__sourceControlExecuted===1,outcomes};
  console.log('NATIVE ADDON FORMAT RESULTS '+JSON.stringify(summary));
  if(resolved!==8||refused!==8||uncached!==8||__addonSourceExecuted!==0||summary.staticBodyExecuted||!dynamic||!allowed.includes(dynamic.code)||!missing||missing.code!=='MODULE_NOT_FOUND'||!summary.sourceControls)throw Error('Native addon format refusal mismatch');
}
main().catch(error=>{console.error(error);process.exitCode=1;});
