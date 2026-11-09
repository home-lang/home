function run(require) {
  const exports = 2;
  const __filename = 3;
  const __dirname = 4;
  return [require, exports, __filename, __dirname];
}
export const result = run(1);
