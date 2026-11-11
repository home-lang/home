import { Database } from 'bun:sqlite';
const db = new Database(process.argv[2], { readonly: true });
try {
  const row = db.query('SELECT value,blob FROM persisted WHERE id = ?').get(3);
  if (row.value !== 'written by independent sqlite3' || Array.from(row.blob).join() !== '16,32') throw new Error('independent SQLite update was not observed');
  console.log('SQLITE INDEPENDENT UPDATE OBSERVED');
} finally { db.close(true); }
