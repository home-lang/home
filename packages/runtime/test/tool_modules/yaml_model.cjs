module.exports = function model(value, seen = new Map()) {
  if (value === null) return ["null"];
  if (typeof value === "number") return ["number", Object.is(value, -0) ? "-0" : String(value)];
  if (typeof value !== "object") return [typeof value, value];
  if (seen.has(value)) return ["ref", seen.get(value)];
  const id = seen.size;
  seen.set(value, id);
  if (Array.isArray(value)) return ["array", id, value.map(item => model(item, seen))];
  return ["object", id, Object.keys(value).sort().map(key => [key, model(value[key], seen)])];
};
