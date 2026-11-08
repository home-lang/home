import { markdown } from 'bun';
for (const kind of ['buffer', 'view']) {
  const buffer = new ArrayBuffer(8);
  new Uint8Array(buffer).set([35, 32, 114, 101, 97, 108, 10]);
  const input = kind === 'buffer' ? buffer : new Uint8Array(buffer);
  let failed = false;
  try {
    markdown.html(input, { get tables() { buffer.transfer(); return true; } });
  }
  catch (error) { failed = error.code === 'ERR_HOME_MARKDOWN_BUFFER_CHANGED'; }
  if (!failed) throw new Error('reentrant buffer detachment was not refused');
}
console.log('OK Markdown reentrant buffer detachment is explicitly refused');
