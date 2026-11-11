// Real SQLite statements and connections are owned by the native context host.
globalThis.__home_tool_sqlite_factory = function(native, Buffer) {
  'use strict';
  const parse = JSON.parse;
  const stringify = JSON.stringify;
  const dbs = new WeakMap();
  const stmts = new WeakMap();
  const bytes = Uint8Array;
  const secret = {};
  let savepoint = 0;
  function unsupported(message) {
    const e = new Error(message); e.code = 'ERR_HOME_UNSUPPORTED'; throw e;
  }
  class SQLiteError extends Error {
    constructor(message, detail) {
      super(message); this.name = 'SQLiteError';
      this.code = detail.code; this.errno = detail.errno; this.byteOffset = detail.byteOffset;
    }
  }
  function call(request) {
    const raw = native(stringify(request));
    if (raw === null) throw new Error('Native SQLite operation failed');
    const result = parse(raw);
    if (result.failure) {
      const f = result.failure;
      if (f.kind === 'sqlite') throw new SQLiteError(f.message, f);
      if (f.kind === 'closed') throw new RangeError('Cannot use a closed database');
      if (f.kind === 'finalized') throw new Error('Statement has finalized');
      const e = new Error(f.message); if (f.kind === 'host') e.code = f.code; throw e;
    }
    return result;
  }
  function dbState(db, allowClosed) {
    const s = dbs.get(db);
    if (!s) throw new TypeError('Invalid SQLite database receiver');
    if (s.closed && !allowClosed) throw new RangeError('Cannot use a closed database');
    return s;
  }
  function stmtState(stmt, allowFinalized) {
    const s = stmts.get(stmt);
    if (!s) throw new TypeError('Invalid SQLite statement receiver');
    if (s.finalized && !allowFinalized) throw new Error(s.closedByDatabase ? 'Database has closed' : 'Statement has finalized');
    return s;
  }
  function hex(data) { return Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString('hex'); }
  function cell(value, safe) {
    if (value === null || value === undefined) return { kind: 'null_value' };
    if (typeof value === 'string') return { kind: 'text', value: value };
    if (typeof value === 'bigint') {
      if (safe && (value < -9223372036854775808n || value > 9223372036854775807n)) throw new RangeError(`BigInt value '${value}' is out of range`);
      return { kind: 'integer', value: String(value) };
    }
    if (typeof value === 'boolean') return { kind: 'integer', value: value ? '1' : '0' };
    if (typeof value === 'number') {
      return { kind: Number.isSafeInteger(value) && !Object.is(value, -0) ? 'integer' : 'real', value: Object.is(value, -0) ? '-0' : String(value) };
    }
    if (ArrayBuffer.isView(value)) return { kind: 'blob', value: hex(value) };
    if (value instanceof ArrayBuffer) return { kind: 'blob', value: hex(new bytes(value)) };
    throw new TypeError('SQLite can only bind strings, numbers, bigints, booleans, null and binary views');
  }
  function bindings(args, strict, safe) {
    if (!args.length) return { specified: false };
    if (args.length === 1 && args[0] !== null && typeof args[0] === 'object' && !ArrayBuffer.isView(args[0]) && !(args[0] instanceof ArrayBuffer) && !Array.isArray(args[0])) {
      return { specified: true, strict: strict, named: Object.keys(args[0]).map(name => ({ name: name, value: cell(args[0][name], safe) })) };
    }
    const values = args.length === 1 && Array.isArray(args[0]) ? args[0] : args;
    return { specified: true, strict: strict, values: values.map(value => cell(value, safe)) };
  }
  function unpack(value, safe) {
    if (value.kind === 'null_value') return null;
    if (value.kind === 'integer') return safe ? BigInt(value.value) : Number(value.value);
    if (value.kind === 'real') return Number(value.value);
    const data = Buffer.from(value.value, 'hex');
    if (value.kind === 'blob') return new bytes(data);
    return data.toString('utf8');
  }
  function row(values, columns, s, arrays) {
    const decoded = values.map(value => unpack(value, s.safe));
    if (arrays) return decoded;
    const result = s.rowPrototype ? Object.create(s.rowPrototype) : {};
    columns.forEach((name, i) => Object.defineProperty(result, name, { value: decoded[i], enumerable: true, writable: true, configurable: true }));
    return result;
  }
  function changes(result, safe) { return { changes: result.changes, lastInsertRowid: safe ? BigInt(result.last_insert_rowid) : Number(result.last_insert_rowid) }; }
  function sqlText(sql) {
    if (typeof sql !== 'string') throw new TypeError('SQL must be a string');
    if (!sql.trim()) throw new Error('SQL query is empty');
    return sql;
  }
  function runStatement(stmt, mode, args, arrays) {
    const s = stmtState(stmt);
    if (s.iterating) unsupported('A SQLite statement cannot be reused during its active iterator');
    const result = call({ op: 'execute', statement: s.id, mode: mode, bindings: bindings(args, s.strict, s.safe) });
    if (mode === 'run') return changes(result, s.safe);
    if (mode === 'get') return result.rows.length ? row(result.rows[0], result.columns, s, arrays) : null;
    return result.rows.map(values => row(values, result.columns, s, arrays));
  }
  class Statement {
    constructor(key, database, id, meta, cached) {
      if (key !== secret) throw new TypeError('Statements are created by Database.prepare or Database.query');
      const db = dbState(database);
      const s = { id: id, database: database, safe: db.safe, strict: db.strict, cached: cached, finalized: false, iterating: false, rowPrototype: null, meta: meta };
      stmts.set(this, s); db.statements.add(s);
    }
    all(...args) { return runStatement(this, 'all', args, false); }
    get(...args) { return runStatement(this, 'get', args, false); }
    run(...args) { return runStatement(this, 'run', args, false); }
    values(...args) { return runStatement(this, 'all', args, true); }
    *iterate(...args) {
      const s = stmtState(this);
      if (s.iterating) unsupported('A SQLite statement cannot have overlapping iterators');
      call({ op: 'begin', statement: s.id, bindings: bindings(args, s.strict, s.safe) });
      s.iterating = true;
      try {
        for (;;) {
          stmtState(this);
          const result = call({ op: 'next', statement: s.id, mode: 'get' });
          if (!result.rows.length) return;
          yield row(result.rows[0], result.columns, s, false);
        }
      } finally {
        s.iterating = false;
        if (!s.finalized) call({ op: 'reset', statement: s.id });
      }
    }
    finalize() {
      const s = stmtState(this, true);
      if (!s.finalized) { call({ op: 'finalize', statement: s.id }); s.finalized = true; dbState(s.database, true).statements.delete(s); }
    }
    get isFinalized() { return stmtState(this, true).finalized; }
    get columnNames() { const s = stmtState(this); return call({ op: 'statement_info', statement: s.id }).columns; }
    get paramsCount() { const s = stmtState(this); return s.meta.names.length; }
    get readonly() { return stmtState(this).meta.readonly; }
    get reader() { return stmtState(this).meta.reader; }
    safeIntegers(enabled) { const s = stmtState(this); if (!arguments.length) return s.safe; s.safe = !!enabled; return this; }
    as(Type) { const s = stmtState(this); if (typeof Type !== 'function' || !Type.prototype) throw new TypeError('Expected a row class'); s.rowPrototype = Type.prototype; return this; }
    toString() { const s = stmtState(this, true); return s.finalized ? '' : call({ op: 'statement_info', statement: s.id }).expanded; }
    toJSON() { const s = stmtState(this, true); return { sql: this.toString(), isFinalized: s.finalized, paramsCount: s.finalized ? 0 : this.paramsCount, columnNames: s.finalized ? [] : this.columnNames }; }
    get native() { unsupported('Home does not expose unsafe SQLite statement pointers'); }
    get columnTypes() { unsupported('SQLite columnTypes metadata is not implemented'); }
    get declaredTypes() { unsupported('SQLite declaredTypes metadata is not implemented'); }
  }
  class Database {
    constructor(path = ':memory:', options = {}) {
      if (typeof path !== 'string' || path.includes('\0')) throw new TypeError('SQLite filename must be a string without NUL bytes');
      let flags;
      if (typeof options === 'number') {
        if (!Number.isInteger(options) || (options & ~0x10047) !== 0 || !(options & 3) || (options & 3) === 3) unsupported('Unsupported SQLite open flags');
        flags = options; options = {};
      } else {
        if (!options || typeof options !== 'object') throw new TypeError('SQLite options must be an object or open flags');
        for (const key of Object.keys(options)) {
          if (!['readonly', 'readwrite', 'create', 'strict', 'safeIntegers'].includes(key)) unsupported(`Unsupported SQLite option: ${key}`);
          if (typeof options[key] !== 'boolean') throw new TypeError('SQLite options must be booleans');
        }
        if (options.readonly && (options.create || options.readwrite)) throw new TypeError('SQLite readonly contradicts create/readwrite');
        const readonly = options.readonly || options.readwrite === false;
        flags = readonly ? 1 : 2 | (options.create === false ? 0 : 4);
      }
      const result = call({ op: 'open', path: path, flags: flags });
      dbs.set(this, { id: result.id, safe: !!options.safeIntegers, strict: !!options.strict, closed: false, cache: new Map(), statements: new Set() });
      Object.defineProperty(this, 'filename', { value: path, enumerable: true });
    }
    static open(path, options) { return new Database(path, options); }
    static setCustomSQLite() { unsupported('Home uses its owned SQLite build, not custom runtime libraries'); }
    static deserialize() { unsupported('SQLite database deserialization is not implemented'); }
    get handle() { unsupported('Home does not expose unsafe SQLite connection pointers'); }
    get inTransaction() { const s = dbState(this); return call({ op: 'info', database: s.id }).in_transaction; }
    prepare(sql, ...args) {
      const s = dbState(this); sql = sqlText(sql);
      const meta = call({ op: 'prepare', database: s.id, sql: sql });
      const stmt = new Statement(secret, this, meta.id, meta, false);
      if (args.length) {
        try { call({ op: 'begin', statement: meta.id, bindings: bindings(args, s.strict, s.safe) }); }
        catch (error) { stmt.finalize(); throw error; }
      }
      return stmt;
    }
    query(sql) {
      const s = dbState(this); sql = sqlText(sql);
      if (s.cache.has(sql)) {
        const found = s.cache.get(sql); s.cache.delete(sql); s.cache.set(sql, found);
        if (!found.isFinalized) return found;
      }
      const capacity = Database.MAX_QUERY_CACHE_SIZE;
      if (!Number.isSafeInteger(capacity) || capacity < 0) throw new RangeError('Invalid SQLite query-cache capacity');
      const meta = call({ op: 'prepare', database: s.id, sql: sql, cached: true });
      const stmt = new Statement(secret, this, meta.id, meta, true);
      if (sql.length <= 65536 && capacity > 0) {
        s.cache.set(sql, stmt);
        while (s.cache.size > capacity) s.cache.delete(s.cache.keys().next().value);
      }
      return stmt;
    }
    clearQueryCache() {
      const s = dbState(this);
      for (const stmt of s.cache.values()) stmt.finalize();
      s.cache.clear();
    }
    run(sql, ...args) { const s = dbState(this); return changes(call({ op: 'exec', database: s.id, sql: sqlText(sql), bindings: bindings(args, s.strict, s.safe) }), s.safe); }
    exec(sql, ...args) { return this.run(sql, ...args); }
    close(force = false) {
      const s = dbState(this, true);
      call({ op: 'close', database: s.id, force: !!force });
      s.closed = true; s.cache.clear();
      for (const state of s.statements) if (force || state.cached) { state.finalized = true; state.closedByDatabase = true; s.statements.delete(state); }
    }
    transaction(fn) {
      dbState(this);
      if (typeof fn !== 'function') throw new TypeError('A transaction requires a function');
      const database = this;
      function wrapper(mode) {
        return function(...args) {
          const nested = database.inTransaction;
          const name = `home_sqlite_${++savepoint}`;
          database.exec(nested ? `SAVEPOINT ${name}` : `BEGIN ${mode}`);
          try {
            const value = Reflect.apply(fn, this, args);
            if (value && typeof value.then === 'function') unsupported('SQLite transaction functions must be synchronous');
            database.exec(nested ? `RELEASE ${name}` : 'COMMIT');
            return value;
          } catch (error) {
            if (database.inTransaction) {
              if (nested) { database.exec(`ROLLBACK TO ${name}`); database.exec(`RELEASE ${name}`); }
              else database.exec('ROLLBACK');
            }
            throw error;
          }
        };
      }
      const result = wrapper('DEFERRED');
      for (const mode of ['deferred', 'immediate', 'exclusive']) Object.defineProperty(result, mode, { value: wrapper(mode.toUpperCase()) });
      Object.defineProperty(result, 'default', { value: result });
      Object.defineProperty(result, 'database', { value: database, enumerable: true });
      return result;
    }
    loadExtension() { unsupported('SQLite extension loading is not implemented'); }
    serialize() { unsupported('SQLite database serialization is not implemented'); }
    fileControl() { unsupported('SQLite file-control operations are not implemented'); }
    function() { unsupported('SQLite JavaScript scalar callbacks are not implemented'); }
    aggregate() { unsupported('SQLite JavaScript aggregate callbacks are not implemented'); }
  }
  Database.MAX_QUERY_CACHE_SIZE = 20;
  if (typeof Symbol.dispose === 'symbol') {
    Object.defineProperty(Database.prototype, Symbol.dispose, { value() { this.close(true); } });
    Object.defineProperty(Statement.prototype, Symbol.dispose, { value() { this.finalize(); } });
  }
  const constants = Object.freeze({ SQLITE_OPEN_READONLY: 1, SQLITE_OPEN_READWRITE: 2, SQLITE_OPEN_CREATE: 4, SQLITE_OPEN_URI: 64, SQLITE_OPEN_FULLMUTEX: 65536 });
  return { Database: Database, SQLiteError: SQLiteError, Statement: Statement, __esModule: true, constants: constants, default: Database };
};
