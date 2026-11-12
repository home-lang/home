(function() {
  globalThis.__home_console_assert_factory = function(consoleObject, nativeWarn) {
    const apply = Reflect.apply;
    const stringify = JSON.stringify;
    const is = Object.is;
    const stringValue = String, numberValue = Number, integerValue = parseInt, floatValue = parseFloat;
    const slice = Array.prototype.slice, unshift = Array.prototype.unshift;
    function unsupported() {
      const error = new Error('Home console.assert supports primitive and JSON formatting; object inspection is unavailable');
      error.code = 'ERR_HOME_UNSUPPORTED';
      throw error;
    }
    function primitive(value) {
      if (value !== null && (typeof value === 'object' || typeof value === 'function')) unsupported();
      if (typeof value === 'bigint') return stringValue(value) + 'n';
      if (is(value, -0)) return '-0';
      return stringValue(value);
    }
    function format(args) {
      const first = args[0];
      if (args.length === 1) return first;
      let output = '', next = 1;
      for (let i = 0; i < first.length; ++i) {
        if (first[i] !== '%' || i + 1 === first.length) { output += first[i]; continue; }
        const code = first[i + 1];
        if (code === '%') { output += '%'; ++i; continue; }
        if (next === args.length || !(code === 's' || code === 'd' || code === 'i' || code === 'f' || code === 'j' || code === 'c' || code === 'o' || code === 'O')) { output += '%'; continue; }
        const value = args[next++];
        ++i;
        if (code === 'o' || code === 'O') unsupported();
        if (code === 'c') continue;
        if (code === 'j') { output += stringify(value); continue; }
        if (code === 's') { output += primitive(value); continue; }
        if (value !== null && (typeof value === 'object' || typeof value === 'function')) unsupported();
        if (typeof value === 'symbol') { output += 'NaN'; continue; }
        if (typeof value === 'bigint' && code !== 'f') { output += primitive(value); continue; }
        const number = code === 'd' ? numberValue(value) : code === 'i' ? integerValue(value) : floatValue(value);
        output += primitive(number);
      }
      for (; next < args.length; ++next) output += ' ' + primitive(args[next]);
      return output;
    }
    // Method syntax preserves the non-constructible, zero-arity surface.
    // Capturing the console mirrors Node's bound method while still honoring
    // a replaced warn method, without invoking formatting hooks on true values.
    return {
      assert(...values) {
        if (values[0]) return;
        const messages = apply(slice, values, [1]);
        if (typeof messages[0] === 'string') messages[0] = 'Assertion failed: ' + messages[0];
        else apply(unshift, messages, ['Assertion failed']);
        const warn = consoleObject.warn;
        if (warn !== nativeWarn) { apply(warn, consoleObject, messages); return; }
        nativeWarn(format(messages));
      },
    }.assert;
  };
})();
