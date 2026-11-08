import fs, { readFileSync, existsSync } from "node:fs";
export const okay = fs.readFileSync === readFileSync && fs.existsSync === existsSync && existsSync(import.meta.dirname);
