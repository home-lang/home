function check(value, message) { if (!value) throw new Error(message); }
const map = { '\n': 'LF', '\r\n': 'CRLF', 'a\'b"c': 'quotes', 'a${x}\n': 'dollar', '\ud800': 'surrogate' };
check(map['\n'] === 'LF' && map['\r\n'] === 'CRLF', 'line break keys');
check(map['a\'b"c'] === 'quotes' && map['a${x}\n'] === 'dollar' && map['\ud800'] === 'surrogate', 'cooked property names');
const methods = { '\n'() { return 'method'; }, get '\r\n'() { return 'getter'; }, set 'a\'b"c'(value) { this.value = value; } };
check(methods['\n']() === 'method' && methods['\r\n'] === 'getter', 'method and accessor names');
methods['a\'b"c'] = 'setter';
check(methods.value === 'setter', 'setter');
class Names { '\n'() { return 'class'; } get '\r\n'() { return 'class getter'; } }
check(new Names()['\n']() === 'class' && new Names()['\r\n'] === 'class getter', 'class names');
const escapedCharsMap = new Map(Object.entries({ '\n': '\\n', '\r\n': '\\r\\n' }));
check(escapedCharsMap.get('\n') === '\\n' && escapedCharsMap.get('\r\n') === '\\r\\n', 'actual TypeScript character map');
console.log('OK exact quoted property names and TypeScript character map');
