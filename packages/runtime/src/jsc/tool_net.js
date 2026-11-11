// Numeric address operations only. No socket, server or name resolver is
// advertised by this adapter; those require a separate native host contract.
globalThis.__home_tool_net_factory = function() {
  'use strict';
  const apply = Reflect.apply, toBigInt = BigInt;
  const concat = String.prototype.concat, split = String.prototype.split;
  const slice = String.prototype.slice, indexOf = String.prototype.indexOf;
  const charCode = String.prototype.charCodeAt, lower = String.prototype.toLowerCase;
  const integer = Number.isInteger;
  const numberString = Number.prototype.toString;
  const states = new WeakMap(), get = WeakMap.prototype.get, set = WeakMap.prototype.set;
  const mapped = 0xffffn << 32n;
  function string(value) { return apply(concat, '', [value]); }
  function part(value, start, end) { return apply(slice, value, [start, end]); }
  function find(value, needle) { return apply(indexOf, value, [needle]); }
  function code(value, i) { return apply(charCode, value, [i]); }
  function error(Type, name, message) { const e = new Type(message); e.code = name; throw e; }
  function requireString(value, name) {
    if (typeof value !== 'string') error(TypeError, 'ERR_INVALID_ARG_TYPE', `${name} must be a string`);
  }
  function ipv4(text) {
    if (text.length < 7 || text.length > 15) return null;
    const fields = apply(split, text, ['.']);
    if (fields.length !== 4) return null;
    let value = 0n;
    for (const field of fields) {
      if (!field.length || field.length > 3 || (field.length > 1 && field[0] === '0')) return null;
      let n = 0;
      for (let i = 0; i < field.length; ++i) { const c = code(field, i); if (c < 48 || c > 57) return null; n = n * 10 + c - 48; }
      if (n > 255) return null;
      value = (value << 8n) | toBigInt(n);
    }
    return value;
  }
  function ipv6(text, nativeScope) {
    const scope = find(text, '%');
    if (scope >= 0) {
      if (!nativeScope) {
        if (scope === text.length - 1) return null;
        for (let i = scope + 1; i < text.length; ++i) {
          const c = code(text, i);
          if (!((c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c === 45 || c === 46 || c === 58)) return null;
        }
      }
      text = part(text, 0, scope);
    }
    if (text.length < 2 || text.length > 45 || find(text, ':') < 0) return null;
    const compressed = find(text, '::');
    if (compressed >= 0 && find(part(text, compressed + 2), '::') >= 0) return null;
    const leftText = compressed < 0 ? text : part(text, 0, compressed);
    const rightText = compressed < 0 ? '' : part(text, compressed + 2);
    const left = leftText ? apply(split, leftText, [':']) : [];
    const right = rightText ? apply(split, rightText, [':']) : [];
    function fields(tokens, allowV4) {
      const values = [];
      for (let i = 0; i < tokens.length; ++i) {
        const field = tokens[i];
        if (find(field, '.') >= 0) {
          if (!allowV4 || i !== tokens.length - 1) return null;
          const n = ipv4(field); if (n === null) return null;
          values[values.length] = Number(n >> 16n); values[values.length] = Number(n & 65535n);
        } else {
          if (!field.length || field.length > 4) return null;
          let n = 0;
          for (let j = 0; j < field.length; ++j) {
            const c = code(field, j);
            const digit = c >= 48 && c <= 57 ? c - 48 : c >= 65 && c <= 70 ? c - 55 : c >= 97 && c <= 102 ? c - 87 : -1;
            if (digit < 0) return null; n = n * 16 + digit;
          }
          values[values.length] = n;
        }
      }
      return values;
    }
    const a = fields(left, compressed < 0), b = fields(right, true);
    if (!a || !b) return null;
    const missing = 8 - a.length - b.length;
    if (compressed < 0 ? missing !== 0 : missing < 1) return null;
    let value = 0n;
    for (const n of a) value = (value << 16n) | toBigInt(n);
    value <<= toBigInt(missing * 16);
    for (const n of b) value = (value << 16n) | toBigInt(n);
    return value;
  }
  function isIPv4(value) { return ipv4(string(value)) !== null; }
  function isIPv6(value) { return ipv6(string(value), false) !== null; }
  function isIP(value) { return isIPv4(value) ? 4 : isIPv6(value) ? 6 : 0; }
  function dotted(value) {
    return `${Number((value >> 24n) & 255n)}.${Number((value >> 16n) & 255n)}.${Number((value >> 8n) & 255n)}.${Number(value & 255n)}`;
  }
  function canonical(value, family) {
    if (family === 'ipv4') return dotted(value);
    if ((value >> 32n) === 65535n) return `::ffff:${dotted(value)}`;
    if ((value >> 32n) === 0n && value > 65535n) return `::${dotted(value)}`;
    const words = [];
    for (let i = 0; i < 8; ++i) words[i] = Number((value >> toBigInt((7 - i) * 16)) & 65535n);
    let bestStart = -1, bestLength = 1;
    for (let i = 0; i < 8;) {
      if (words[i]) { ++i; continue; }
      const start = i; while (i < 8 && words[i] === 0) ++i;
      if (i - start > bestLength) { bestStart = start; bestLength = i - start; }
    }
    let result = '';
    for (let i = 0; i < 8; ++i) {
      if (i === bestStart) { result += '::'; i += bestLength - 1; continue; }
      if (result && result[result.length - 1] !== ':') result += ':';
      result += apply(numberString, words[i], [16]);
    }
    return result;
  }
  function familyOf(family) {
    requireString(family, 'family');
    family = apply(lower, family, []);
    if (family !== 'ipv4' && family !== 'ipv6') error(TypeError, 'ERR_INVALID_ARG_VALUE', 'family must be ipv4 or ipv6');
    return family;
  }
  function address(text, family, checking) {
    requireString(text, 'address');
    // Native SocketAddress truncates at NUL. This numeric-only profile refuses
    // that ambiguous spelling rather than silently matching a different input.
    if (find(text, '\0') >= 0) error(Error, 'ERR_HOME_UNSUPPORTED', 'Home BlockList refuses embedded NUL addresses');
    const value = family === 'ipv4' ? ipv4(text) : ipv6(text, true);
    if (value === null && !checking) error(Error, 'ERR_INVALID_ADDRESS', 'Invalid IP address');
    return value;
  }
  function state(receiver) {
    const result = apply(get, states, [receiver]);
    if (!result) error(TypeError, 'ERR_INVALID_THIS', 'Value of this must be a BlockList');
    return result;
  }
  function normalized(value, family) { return family === 'ipv4' ? mapped | value : value; }
  class BlockList {
    constructor() { apply(set, states, [this, []]); }
    addAddress(text, family = 'ipv4') {
      const rules = state(this); requireString(text, 'address'); family = familyOf(family);
      const value = address(text, family, false), n = normalized(value, family);
      rules[rules.length] = { start: n, end: n, text: `Address: ${family === 'ipv4' ? 'IPv4' : 'IPv6'} ${canonical(value, family)}` };
    }
    addRange(start, end, family = 'ipv4') {
      const rules = state(this); requireString(start, 'start'); requireString(end, 'end'); family = familyOf(family);
      const a = address(start, family, false), b = address(end, family, false);
      if (a > b) error(TypeError, 'ERR_INVALID_ARG_VALUE', 'start must come before end');
      rules[rules.length] = { start: normalized(a, family), end: normalized(b, family), text: `Range: ${family === 'ipv4' ? 'IPv4' : 'IPv6'} ${canonical(a, family)}-${canonical(b, family)}` };
    }
    addSubnet(text, prefix, family = 'ipv4') {
      const rules = state(this); requireString(text, 'address'); family = familyOf(family);
      const value = address(text, family, false), width = family === 'ipv4' ? 32 : 128;
      if (typeof prefix !== 'number') error(TypeError, 'ERR_INVALID_ARG_TYPE', 'prefix must be a number');
      if (!integer(prefix) || prefix < 0 || prefix > width) error(RangeError, 'ERR_OUT_OF_RANGE', `prefix must be an integer from 0 to ${width}`);
      const bits = toBigInt(width - prefix), start = (value >> bits) << bits;
      rules[rules.length] = { start: normalized(start, family), end: normalized(start | ((1n << bits) - 1n), family), text: `Subnet: ${family === 'ipv4' ? 'IPv4' : 'IPv6'} ${canonical(value, family)}/${prefix}` };
    }
    check(text, family = 'ipv4') {
      const rules = state(this); requireString(text, 'address'); requireString(family, 'family');
      // Node's check fast path treats any non-ipv4 string as the IPv6 family.
      family = apply(lower, family, []) === 'ipv4' ? 'ipv4' : 'ipv6';
      const value = address(text, family, true); if (value === null) return false;
      const n = normalized(value, family);
      for (const rule of rules) if (n >= rule.start && n <= rule.end) return true;
      return false;
    }
    get rules() {
      const rules = state(this), result = [];
      for (let i = rules.length - 1; i >= 0; --i) result[result.length] = rules[i].text;
      return result;
    }
  }
  return { isIP, isIPv4, isIPv6, BlockList };
};
