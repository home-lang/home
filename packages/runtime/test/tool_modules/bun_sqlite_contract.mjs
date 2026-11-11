import DefaultDatabase, { Database, Statement, SQLiteError } from 'bun:sqlite';
import { createRequire } from 'node:module';
const requireHere = createRequire(import.meta.url);
const results = [];
const failures = [];
function assert(value, label) { if (!value) throw new Error(label); }
function same(a, b) { assert(JSON.stringify(a) === JSON.stringify(b), 'different data: ' + JSON.stringify([a, b])); }
function check(label, fn) { try { fn(); results.push(label); } catch (error) { failures.push({ label, message: String(error) }); } }
function memory(fn, options) { const db = new Database(':memory:', options); try { fn(db); } finally { db.close(true); } }
function throws(fn, code) { let found; try { fn(); } catch (error) { found = error; } assert(found, 'expected error'); if (code) assert(found.code === code, 'wrong code ' + found.code); return found; }
check('module identity and genuine statement instances', () => memory(db => {
  assert(DefaultDatabase === Database && requireHere('bun:sqlite').Database === Database, 'module identity');
  assert(db instanceof Database && db.prepare('SELECT 1') instanceof Statement, 'native classes');
}));
check('actual schema and DML changes', () => memory(db => {
  same(db.run('CREATE TABLE items(id INTEGER PRIMARY KEY, value TEXT)'), { changes: 0, lastInsertRowid: 0 });
  same(db.query('INSERT INTO items(value) VALUES (?)').run('one'), { changes: 1, lastInsertRowid: 1 });
  same(db.query('SELECT * FROM items').all(), [{ id: 1, value: 'one' }]);
}));
check('multi-statement changes include each DML but not triggers', () => memory(db => {
  db.exec('CREATE TABLE x(n INTEGER); CREATE TABLE log(n INTEGER); CREATE TRIGGER t AFTER INSERT ON x BEGIN INSERT INTO log VALUES(new.n); END');
  same(db.run('INSERT INTO x VALUES(1); INSERT INTO x VALUES(2)'), { changes: 2, lastInsertRowid: 2 });
  same(db.query('SELECT n FROM log ORDER BY n').values(), [[1], [2]]);
}));
check('multi-statement binding executes trailing SQL', () => memory(db => {
  db.run('CREATE TABLE x(n INTEGER)');
  same(db.run('INSERT INTO x VALUES(?); INSERT INTO x VALUES(2)', 1), { changes: 2, lastInsertRowid: 2 });
  same(db.query('SELECT n FROM x ORDER BY n').values(), [[1], [2]]);
}));
check('positional arrays and persistent bindings', () => memory(db => {
  const s = db.prepare('SELECT ? AS n', 7);
  same(s.get(), { n: 7 }); same(s.get([8]), { n: 8 }); same(s.get(), { n: 8 });
  same(s.get(undefined), { n: null }); same(s.get(), { n: null });
}));
check('named bindings clear missing fields and accept prefixes', () => memory(db => {
  const s = db.query('SELECT $a AS a, :b AS b, @c AS c');
  same(s.get({ a: 1, ':b': 2, '@c': 3 }), { a: 1, b: 2, c: 3 });
  same(s.get({ $a: 4 }), { a: 4, b: null, c: null });
  same(s.get([]), { a: null, b: null, c: null });
}));
check('strict binding failures remain failures', () => memory(db => {
  const e = throws(() => db.query('SELECT $a AS a').get({ typo: 1 }));
  assert(e.message.includes('Missing parameter'), 'strict missing name');
}, { strict: true }));
check('positional arity is checked', () => memory(db => {
  throws(() => db.query('SELECT ? a, ? b').get(1));
  throws(() => db.query('SELECT ? a').get(1, 2));
}));
check('no rows returns null and empty arrays', () => memory(db => {
  const s = db.query('SELECT 1 WHERE 0'); assert(s.get() === null, 'get no rows'); same(s.all(), []); same(s.values(), []);
}));
check('Unicode and embedded NUL text are stored', () => memory(db => {
  const text = 'snowman ☃ / 🌍 / a\0b';
  db.run('CREATE TABLE t(v TEXT)'); db.query('INSERT INTO t VALUES(?)').run(text);
  same(db.query('SELECT v,length(v) AS n FROM t').get(), { v: text, n: text.indexOf('\0') - 1 });
}));
check('binary views respect byte offsets and empty blobs', () => memory(db => {
  const source = new Uint8Array([99, 0, 1, 255, 88]);
  const row = db.query('SELECT ? AS b, ? AS empty').get(source.subarray(1, 4), new Uint8Array(0));
  assert(row.b instanceof Uint8Array && row.empty instanceof Uint8Array, 'binary result types');
  same(Array.from(row.b), [0, 1, 255]); same(Array.from(row.empty), []);
}));
check('integer64 and safe integer mode preserve exact values', () => memory(db => {
  const s = db.query('SELECT ? AS n'); assert(s.get(9007199254740993n).n === 9007199254740993n, 'exact integer');
  same(db.run('CREATE TABLE x(id INTEGER PRIMARY KEY)').changes, 0);
  const inserted = db.run('INSERT INTO x DEFAULT VALUES'); assert(inserted.lastInsertRowid === 1n && inserted.changes === 1, 'safe row ID');
}, { safeIntegers: true }));
check('statement safe-integer mode toggles independently', () => memory(db => {
  const s = db.query('SELECT ? AS n'); assert(s.safeIntegers() === false, 'default flag');
  assert(s.safeIntegers(true) === s, 'fluent safe flag'); assert(s.get(9007199254740993n).n === 9007199254740993n, 'statement integer');
  assert(s.safeIntegers(false) === s && typeof s.get(1n).n === 'number', 'number mode');
}));
check('BigInt default wrapping and safe-range refusal are distinct', () => memory(db => {
  const s = db.query('SELECT CAST(? AS TEXT) AS n');
  same(s.get(9223372036854775808n), { n: '-9223372036854775808' });
  same(s.get(18446744073709551615n), { n: '-1' });
  s.safeIntegers(true);
  assert(throws(() => s.get(9223372036854775808n)) instanceof RangeError, 'safe binding range');
}));
check('numeric SQL storage classes come from real binding types', () => memory(db => {
  const s = db.query('SELECT typeof(?) AS t, ? AS n');
  same(s.get(1, 1), { t: 'integer', n: 1 }); same(s.get(1.5, 1.5), { t: 'real', n: 1.5 });
  assert(s.get(-0, -0).t === 'real', 'negative zero storage');
  assert(s.get(NaN, NaN).n === null, 'SQLite NaN to NULL');
  const inf = s.get(Infinity, Infinity); assert(inf.t === 'real' && inf.n === Infinity, 'infinite real');
}));
check('statement metadata and expanded SQL are native', () => memory(db => {
  const s = db.query('SELECT ? AS value'); assert(s.paramsCount === 1 && s.readonly && s.reader, 'statement metadata');
  same(s.columnNames, ['value']); s.get("it's bound"); assert(s.toString().includes("'it''s bound'"), 'expanded SQL');
  same(s.toJSON().columnNames, ['value']); assert(!s.toJSON().isFinalized, 'JSON metadata');
}));
check('row class prototypes do not invoke constructors', () => memory(db => {
  let calls = 0;
  class Row { constructor() { calls++; } get doubled() { return this.n * 2; } }
  const s = db.query('SELECT 3 AS n'); assert(s.as(Row) === s, 'fluent class');
  const row = s.get(); assert(row instanceof Row && row.doubled === 6 && calls === 0, 'row class semantics');
}));
check('column names cannot change row prototypes', () => memory(db => {
  const row = db.query("SELECT 'value' AS __proto__, 1 AS duplicate, 2 AS duplicate").get();
  assert(Object.getPrototypeOf(row) === Object.prototype, 'row prototype changed');
  assert(Object.prototype.hasOwnProperty.call(row, '__proto__') && row.__proto__ === 'value' && row.duplicate === 2, 'column data');
}));
check('native iterators are lazy and release cursors after break', () => memory(db => {
  db.run('CREATE TABLE x(n INTEGER); INSERT INTO x VALUES(1); INSERT INTO x VALUES(2)');
  const s = db.query('SELECT n FROM x ORDER BY n'); const iterator = s.iterate();
  db.run('INSERT INTO x VALUES(3)'); const values = [];
  for (const row of iterator) { values.push(row.n); if (values.length === 2) break; }
  same(values, [1, 2]); same(s.all(), [{ n: 1 }, { n: 2 }, { n: 3 }]);
}));
check('transaction commits native writes and preserves this/return', () => memory(db => {
  db.run('CREATE TABLE x(n INTEGER)'); const receiver = {};
  const transaction = db.transaction(function(n) { assert(this === receiver && db.inTransaction, 'transaction state'); db.run('INSERT INTO x VALUES(?)', n); return n + 1; });
  assert(transaction.call(receiver, 4) === 5 && transaction.database === db && !db.inTransaction, 'transaction completion');
  same(db.query('SELECT n FROM x').get(), { n: 4 });
}));
check('transaction errors roll back actual writes', () => memory(db => {
  db.run('CREATE TABLE x(n INTEGER)'); const sentinel = new Error('rollback witness');
  const e = throws(() => db.transaction(() => { db.run('INSERT INTO x VALUES(1)'); throw sentinel; })());
  assert(e === sentinel && !db.inTransaction, 'transaction error identity'); same(db.query('SELECT COUNT(*) n FROM x').get(), { n: 0 });
}));
check('nested transactions use real savepoint rollback', () => memory(db => {
  db.run('CREATE TABLE x(n INTEGER)');
  db.transaction(() => { db.run('INSERT INTO x VALUES(1)'); throws(() => db.transaction(() => { db.run('INSERT INTO x VALUES(2)'); throw new Error('inner'); })()); db.run('INSERT INTO x VALUES(3)'); })();
  same(db.query('SELECT n FROM x ORDER BY n').values(), [[1], [3]]);
}));
check('transaction modes and manual transaction state', () => memory(db => {
  const t = db.transaction(() => assert(db.inTransaction, 'native active transaction'));
  t.deferred(); t.immediate(); t.exclusive();
  db.exec('BEGIN'); assert(db.inTransaction, 'manual BEGIN'); db.exec('ROLLBACK'); assert(!db.inTransaction, 'manual ROLLBACK');
}));
check('query caching does not cache results', () => memory(db => {
  db.run('CREATE TABLE x(n INTEGER)'); const s = db.query('SELECT COUNT(*) n FROM x');
  assert(db.query('SELECT COUNT(*) n FROM x') === s, 'query identity'); same(s.get(), { n: 0 });
  db.run('INSERT INTO x VALUES(1)'); same(s.get(), { n: 1 });
}));
check('clearing the query cache finalizes only owned queries', () => memory(db => {
  const cached = db.query('SELECT 1'); const explicit = db.prepare('SELECT 2 AS n');
  db.clearQueryCache(); assert(cached.isFinalized, 'cached statement ownership'); throws(() => cached.get()); same(explicit.get(), { n: 2 });
}));
check('cache eviction leaves outstanding statements usable', () => memory(db => {
  const old = db.query('SELECT 0 AS n'); for (let i = 1; i <= Database.MAX_QUERY_CACHE_SIZE + 2; i++) db.query('SELECT ' + i + ' AS n').get();
  assert(!old.isFinalized && db.query('SELECT 0 AS n') !== old, 'LRU eviction'); same(old.get(), { n: 0 });
}));
check('real constraint errors retain native error codes', () => memory(db => {
  db.run('CREATE TABLE x(id INTEGER PRIMARY KEY); INSERT INTO x VALUES(1)');
  const e = throws(() => db.query('INSERT INTO x VALUES(?)').run(1), 'SQLITE_CONSTRAINT_PRIMARYKEY');
  assert(e instanceof SQLiteError && e.errno === 1555 && e.byteOffset === -1, 'native constraint error');
}));
check('syntax errors retain SQLite byte offsets', () => memory(db => {
  const e = throws(() => db.query('SELEC wrong'), 'SQLITE_ERROR'); assert(e instanceof SQLiteError && e.byteOffset === 0, 'syntax error offset');
}));
check('statements recover after constraint failures', () => memory(db => {
  db.run('CREATE TABLE x(n INTEGER UNIQUE); INSERT INTO x VALUES(1)'); const s = db.query('INSERT INTO x VALUES(?)');
  throws(() => s.run(1), 'SQLITE_CONSTRAINT_UNIQUE'); assert(s.run(2).changes === 1, 'reuse failed statement');
  same(db.query('SELECT n FROM x ORDER BY n').values(), [[1], [2]]);
}));
check('finalize is safe and rejects further execution', () => memory(db => {
  const s = db.prepare('SELECT 1'); s.finalize(); s.finalize(); assert(s.isFinalized, 'finalized flag'); throws(() => s.get());
}));
check('explicit statements can outlive close(false)', () => {
  const db = new Database(':memory:'); const s = db.prepare('SELECT 7 AS n'); const cached = db.query('SELECT 8');
  db.close(); same(s.get(), { n: 7 }); assert(cached.isFinalized, 'owned query finalized'); throws(() => db.query('SELECT 9'));
  db.close(true); assert(s.isFinalized, 'late force close'); throws(() => s.get());
});
check('physical SQLite file persists typed values and enforces readonly', () => {
  const path = process.argv[2]; assert(path, 'fixture requires a real file path');
  const db = new Database(path, { create: true });
  try {
    db.exec('CREATE TABLE persisted(id INTEGER PRIMARY KEY, value TEXT, blob BLOB);');
    db.query('INSERT INTO persisted VALUES(?,?,?)').run(1, 'real SQLite 🌍', new Uint8Array([0, 1, 255]));
    db.transaction(() => db.query('INSERT INTO persisted VALUES(?,?,?)').run(2, 'transaction', new Uint8Array(0)))();
  } finally { db.close(true); }
  const read = new Database(path, { readonly: true });
  try { same(read.query('SELECT id,value FROM persisted ORDER BY id').values(), [[1, 'real SQLite 🌍'], [2, 'transaction']]); throws(() => read.run('INSERT INTO persisted(id) VALUES(3)'), 'SQLITE_READONLY'); }
  finally { read.close(true); }
});
console.log('BUN SQLITE CORE RESULTS ' + JSON.stringify({ checks: results.length + failures.length, passed: results.length, failures: failures }));
if (failures.length) throw new Error('SQLite core contract failed');
console.log('BUN SQLITE CORE ' + results.length + ' CHECKS OK');
