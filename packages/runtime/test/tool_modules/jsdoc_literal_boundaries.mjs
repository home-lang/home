function check(value, message) { if (!value) throw new Error(message); }
const output = [];
function write(text) { output.push(text); }
function emitJSDoc(text) {
  write('/**');
  if (text) {
    if (text.length) {
      const lines = text.split(/\r\n?|\n/);
      for (const line of lines) { write(line); }
    }
  }
  write('*/');
}
const doubleQuoted = "/** @returns {string} a\n * @returns {number} b */";
const singleQuoted = '/** @returns {string} a\n * @returns {number} b */';
const template = `/** @returns {string} a
 * @returns {number} b */`;
// /** @returns {string} a
// * @returns {number} b */
/* ordinary comment with /** @returns {string} a
 * @returns {number} b */
/**/
/** @returns {string} one genuine tag */
function genuine() { return 'real'; }
emitJSDoc('first\r\nsecond\nthird');
check(output.join('|') === '/**|first|second|third|*/', 'executed nested regexp emitter');
check(doubleQuoted === singleQuoted && template === singleQuoted, 'literal comment data preserved');
check(genuine() === 'real', 'genuine JSDoc remains accepted');
console.log('OK JSDoc literal boundaries and actual nested regexp execution');
