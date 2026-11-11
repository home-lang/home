import { Database } from 'bun:sqlite';
const db = new Database(':memory:');
let refusals = 0;
function unsupported(fn) {
  let error;
  try { fn(); } catch (e) { error = e; }
  if (!error || error.code !== 'ERR_HOME_UNSUPPORTED') throw new Error('Unsupported SQLite capability was accepted');
  refusals++;
}
try {
  unsupported(() => db.loadExtension('must-not-load'));
  unsupported(() => db.serialize());
  unsupported(() => db.fileControl(0, 0));
  unsupported(() => db.function('mustNotRun', () => 1));
  unsupported(() => db.aggregate('mustNotRun', {}));
  unsupported(() => db.handle);
  const stmt = db.prepare('SELECT 1');
  unsupported(() => stmt.native);
  unsupported(() => stmt.columnTypes);
  unsupported(() => stmt.declaredTypes);
  stmt.finalize();
  unsupported(() => Database.setCustomSQLite('must-not-load'));
  unsupported(() => Database.deserialize(new Uint8Array(0)));
  db.run('CREATE TABLE x(n INTEGER)');
  unsupported(() => db.transaction(async () => { db.run('INSERT INTO x VALUES(1)'); })());
  if (db.query('SELECT COUNT(*) AS n FROM x').get().n !== 0) throw new Error('Refused async transaction committed writes');
  if (refusals !== 12) throw new Error('Incomplete unsupported-profile checks');
  console.log('HOME SQLITE UNSUPPORTED 12 REFUSALS OK');
} finally { db.close(true); }
