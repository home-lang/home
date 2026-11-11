// Actual system lookup only. Record queries, custom resolvers and sockets are
// separate host contracts and are deliberately not advertised here.
globalThis.__home_tool_dns_factory = function(nativeLookup, schedule, isIP) {
  'use strict';
  const NativePromise = Promise, parse = JSON.parse, apply = Reflect.apply;
  const charCode = String.prototype.charCodeAt, indexOf = String.prototype.indexOf;
  const hintsMask = nativeLookup();
  function error(Type, code, message) { const e = new Type(message); e.code = code; return e; }
  function invalidType(message) { throw error(TypeError, 'ERR_INVALID_ARG_TYPE', message); }
  function invalidValue(message) { throw error(TypeError, 'ERR_INVALID_ARG_VALUE', message); }
  function unsupported(message) { throw error(Error, 'ERR_HOME_UNSUPPORTED', message); }
  function lookup(hostname, options) {
    if (hostname) {
      if (typeof hostname !== 'string') invalidType('hostname must be a string');
      if (apply(indexOf, hostname, ['\0']) !== -1) invalidValue('hostname must not contain NUL');
    }
    let family = 0, hints = 0, all = false, order = 'verbatim';
    function validFamily(value) { if (value !== 0 && value !== 4 && value !== 6) invalidValue('family must be 0, 4 or 6'); return value + 0; }
    if (typeof options === 'number') family = validFamily(options);
    else if (options !== undefined && options !== null && typeof options !== 'object') invalidType('options must be a number or object');
    else if (options != null) {
      // Snapshot each option once, before the deferred native operation.
      const flags = options.hints, version = options.family, every = options.all;
      const verbatim = options.verbatim, sort = options.order;
      if (flags != null) { if (typeof flags !== 'number') invalidType('hints must be a number'); hints = flags >>> 0; if ((hints & ~hintsMask) !== 0) invalidValue('Unsupported getaddrinfo hints'); }
      if (version != null) family = validFamily(version);
      if (every != null) { if (typeof every !== 'boolean') invalidType('all must be a boolean'); all = every; }
      if (verbatim != null) { if (typeof verbatim !== 'boolean') invalidType('verbatim must be a boolean'); order = verbatim ? 'verbatim' : 'ipv4first'; }
      if (sort != null) { if (sort !== 'verbatim' && sort !== 'ipv4first' && sort !== 'ipv6first') invalidValue('Invalid lookup result order'); order = sort; }
    }
    if (hostname && hostname.length > 1024) unsupported('Home lookup hostname exceeds 1024 code units');
    if (hostname) for (let i = 0; i < hostname.length; ++i) if (apply(charCode, hostname, [i]) > 127) unsupported('Home system lookup requires an ASCII hostname; IDNA is not implemented');
    return new NativePromise(function(resolve, reject) {
      if (!hostname) { reject(error(TypeError, 'ERR_INVALID_ARG_VALUE', 'hostname must be a non-empty string')); return; }
      const matched = isIP(hostname);
      if (matched) { const record = { address: hostname, family: matched }; resolve(all ? [record] : record); return; }
      // A real referenced owner task retains the promise and async context.
      // libc may block this task; this adapter does not claim a libuv pool.
      schedule(function() {
        try {
          const raw = nativeLookup(hostname, family, hints);
          if (typeof raw !== 'string') throw error(Error, 'ERR_HOME_DNS_HOST', 'Native lookup did not return an owned result');
          const answer = parse(raw);
          if (answer.host_error) unsupported(`Home system lookup: ${answer.host_error}`);
          if (answer.failure) {
            const f = answer.failure, e = error(Error, f.code, `getaddrinfo ${f.code} ${hostname}`);
            e.errno = f.errno; e.syscall = 'getaddrinfo'; e.hostname = hostname; e.nativeCode = f.native_code;
            throw e;
          }
          let records = answer.records;
          if (!Array.isArray(records) || records.length === 0) throw error(Error, 'ERR_HOME_DNS_HOST', 'Native lookup returned no address or failure');
          if (order !== 'verbatim') {
            const first = order === 'ipv4first' ? 4 : 6, ordered = [];
            for (const r of records) if (r.family === first) ordered.push(r);
            for (const r of records) if (r.family !== first) ordered.push(r);
            records = ordered;
          }
          resolve(all ? records : records[0]);
        } catch (e) { reject(e); }
      }, 0);
    });
  }
  return { lookup };
};
