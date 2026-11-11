import win32 from 'node:path/win32';
if(Object.keys(win32).sort().join(',')!=='delimiter,isAbsolute,normalize,posix,sep,win32')throw new Error('Unknown Windows path API advertised');
for(const name of ['resolve','relative','join','parse','format','basename','dirname','extname','toNamespacedPath'])if(name in win32)throw new Error('Unimplemented Windows path method advertised: '+name);
if('__home_tool_path_win32_factory' in globalThis)throw new Error('Private Windows path factory leaked');
console.log('HOME WIN32 PATH PROFILE TWO LEXICAL METHODS; DRIVE CWD AND FILESYSTEM APIS ABSENT');
