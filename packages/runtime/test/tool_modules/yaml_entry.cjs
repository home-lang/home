const model = require("./yaml_model.cjs");
const fixture = require("./yaml.expected.json");
if (Bun.YAML !== require("bun").YAML) throw new Error("YAML module/global identity differs");
for (const item of fixture.cases) {
  let value, error;
  try { value = model(Bun.YAML.parse(item.source)); }
  catch (caught) { error = caught.name; }
  if (JSON.stringify(value) !== JSON.stringify(item.value) || error !== item.error) {
    throw new Error("Bun YAML oracle mismatch: " + JSON.stringify(item) + " actual " + JSON.stringify({ value, error }));
  }
}
const prototype = Bun.YAML.parse("__proto__: { polluted: true }");
if (Object.getPrototypeOf(prototype) !== Object.prototype || !Object.prototype.hasOwnProperty.call(prototype, "__proto__") || Object.prototype.polluted !== undefined) throw new Error("YAML property changed an object prototype");
console.log("OK home-tool native YAML parsing");
