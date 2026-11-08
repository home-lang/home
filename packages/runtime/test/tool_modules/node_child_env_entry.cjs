const child = require("node:child_process");
const env = JSON.parse('{"OWNED_CHILD_ENV":"ordinary-configured","__proto__":"prototype-configured"}');
if (!Object.hasOwn(env, "__proto__")) throw new Error("environment fixture lost its own key");
child.execFileSync("/usr/bin/printenv", ["OWNED_CHILD_ENV"], { stdio: "inherit", env });
child.execFileSync("/usr/bin/printenv", ["__proto__"], { stdio: "inherit", env });
console.log("OK home-tool own environment keys");
