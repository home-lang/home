const before = process.cwd();
let rejected = 0;
try { process.chdir('prefix\0suffix'); } catch (error) {
  if (error instanceof TypeError && error.code === 'ERR_INVALID_ARG_VALUE' && process.cwd() === before) rejected++;
}
try { process.chdir(''); } catch (error) {
  if (error.code === 'ENOENT' && error.dest === '' && process.cwd() === before) rejected++;
}
if (rejected !== 2) throw new Error('Home chdir path profile');
console.log('HOME PROCESS CHDIR 2 PATH GUARDS OK');
