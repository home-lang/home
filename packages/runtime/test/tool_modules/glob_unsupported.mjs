import { Glob } from 'bun';
for (const options of [{ followSymlinks: true }, { futureOption: true }]) {
  let code;
  try { Array.from(new Glob('**/*').scanSync(options)); } catch (error) { code = error.code; }
  if (code !== 'ERR_HOME_UNSUPPORTED_GLOB') throw new Error('Unsupported Glob options were ignored');
}
for (const pattern of ['!**/*.md', '../*.md', '/*', '{src/a,lib/b}', '{.hidden,*}']) {
  let code;
  try { Array.from(new Glob(pattern).scanSync()); } catch (error) { code = error.code; }
  if (code !== 'ERR_HOME_UNSUPPORTED_GLOB') throw new Error('Unsupported Glob scan syntax was ignored');
}
console.log('OK explicit unsupported glob scans remain errors');
