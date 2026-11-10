export async function asyncOrigin() { await Promise.resolve(); throw new Error("origin probe"); }
