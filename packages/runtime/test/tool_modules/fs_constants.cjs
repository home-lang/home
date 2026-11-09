const constants=require('node:constants'),alias=require('constants'),fs=require('node:fs');
function check(value,message){if(!value)throw new Error(message);}
check(constants===alias && constants!==fs.constants && Object.getPrototypeOf(constants)===Object.prototype,'constants module identity');
const darwin={"F_OK": 0, "R_OK": 4, "W_OK": 2, "X_OK": 1, "O_RDONLY": 0, "O_WRONLY": 1, "O_RDWR": 2, "O_APPEND": 8, "O_CREAT": 512, "O_EXCL": 2048, "O_NOCTTY": 131072, "O_TRUNC": 1024, "O_DIRECTORY": 1048576, "O_NOFOLLOW": 256, "O_SYNC": 128, "O_DSYNC": 4194304, "O_SYMLINK": 2097152, "O_NONBLOCK": 4, "O_DIRECT": null, "S_IFMT": 61440, "S_IFREG": 32768, "S_IFDIR": 16384, "S_IFCHR": 8192, "S_IFBLK": 24576, "S_IFIFO": 4096, "S_IFLNK": 40960, "S_IFSOCK": 49152, "S_IRWXU": 448, "S_IRUSR": 256, "S_IWUSR": 128, "S_IXUSR": 64, "S_IRWXG": 56, "S_IRGRP": 32, "S_IWGRP": 16, "S_IXGRP": 8, "S_IRWXO": 7, "S_IROTH": 4, "S_IWOTH": 2, "S_IXOTH": 1};
const portable=['F_OK','R_OK','W_OK','X_OK','O_RDONLY','O_WRONLY','O_RDWR','S_IFMT','S_IFREG','S_IFDIR','S_IFCHR','S_IFBLK','S_IFIFO','S_IFLNK','S_IFSOCK','S_IRWXU','S_IRUSR','S_IWUSR','S_IXUSR','S_IRWXG','S_IRGRP','S_IWGRP','S_IXGRP','S_IRWXO','S_IROTH','S_IWOTH','S_IXOTH'];
for(const key of portable){check(constants[key]===darwin[key] && fs.constants[key]===darwin[key],'POSIX numeric '+key);}
if(process.platform==='darwin') for(const key of Object.keys(darwin)){if(darwin[key]===null)check(!(key in constants)&&!(key in fs.constants),'absent platform flag '+key);else check(constants[key]===darwin[key] && fs.constants[key]===darwin[key],'Darwin native flag '+key);}
if(process.platform==='linux') {check(!('O_SYMLINK' in constants)&&!('O_SYMLINK' in fs.constants),'Linux must not invent O_SYMLINK');check((constants.O_SYNC & constants.O_DSYNC)===constants.O_DSYNC && constants.O_SYNC!==constants.O_DSYNC,'Linux O_SYNC includes O_DSYNC');}
for(const table of [constants,fs.constants]) for(const key of portable){const d=Object.getOwnPropertyDescriptor(table,key);check(d.enumerable && !d.writable && !d.configurable,'read-only constant '+key);}
const file=fs.statSync(__filename),dir=fs.statSync(__dirname);
check((file.mode & constants.S_IFMT)===constants.S_IFREG && (dir.mode & constants.S_IFMT)===constants.S_IFDIR,'real native filesystem kinds');
fs.accessSync(__filename,constants.R_OK);
check(globalThis.__home_tool_fs_constants===undefined,'native install table removed');
console.log('OK native POSIX filesystem constants, aliases, descriptors, platform flags and actual metadata');
