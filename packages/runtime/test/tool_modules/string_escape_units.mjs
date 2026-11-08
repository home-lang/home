const cases = [
  ['pair', '\ud83d\udfe2', [0xD83D, 0xDFE2]],
  ['high', '\ud800', [0xD800]],
  ['low', '\udfff', [0xDFFF]],
  ['mixed', 'a\ud800b\udfff', [97, 0xD800, 98, 0xDFFF]],
  ['brace pair', '\u{D83D}\u{DFE2}', [0xD83D, 0xDFE2]],
  ['brace high', '\u{D800}', [0xD800]],
  ['brace low', '\u{DFFF}', [0xDFFF]],
  ['separated', '\ud83dx\udfe2', [0xD83D, 120, 0xDFE2]],
  ['high high', '\ud800\ud801', [0xD800, 0xD801]],
  ['low high', '\udfff\ud800', [0xDFFF, 0xD800]],
  ['escaped slash', '\\ud800', [92, 117, 100, 56, 48, 48]],
  ['latin1', '\xE9\xFF', [233, 255]],
  ['NUL', '\u0000', [0]],
  ['literal emoji', '🟢', [0xD83D, 0xDFE2]],
  ['astral', '\u{10ffff}', [0xDBFF, 0xDFFF]],
  ['BMP', '\uffff', [0xFFFF]],
];
for (const [name, value, expected] of cases) {
  const actual = [];
  for (let i = 0; i < value.length; i++) actual.push(value.charCodeAt(i));
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(name + ': ' + JSON.stringify(actual));
}
const object = { '\ud800': 42 };
if (Object.keys(object)[0].charCodeAt(0) !== 0xD800 || object['\ud800'] !== 42) throw new Error('escaped key');
function returned() { return '\ud83d\udfe2\ud800'; }
if (returned().length !== 3 || returned().charCodeAt(2) !== 0xD800) throw new Error('function literal');
console.log('OK 16 escaped/literal strings, property keys and function code units');
