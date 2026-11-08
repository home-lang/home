const child = require("node:child_process");
if (child !== require("child_process")) throw new Error("child_process identity differs");
const result = child.execFileSync("/bin/sh", ["-c", "printf 'real inherited child output\\n'"], { stdio: "inherit" });
if (result !== null) throw new Error("inherited child returned a captured substitute");
child.execFileSync("/bin/sh", ["-c", 'test "$OWNED_CHILD_ENV" = "configured" && test "$(pwd)" = "$OWNED_CHILD_CWD" && test -z "${HOME+x}"'], {
  stdio: "inherit", cwd: __dirname, env: { OWNED_CHILD_ENV: "configured", OWNED_CHILD_CWD: __dirname },
});
let failed = false;
try { child.execFileSync("/bin/sh", ["-c", "exit 7"], { stdio: "inherit" }); }
catch (error) { failed = error.status === 7 && error.signal === null && error.stdout === null && error.stderr === null; }
if (!failed) throw new Error("child failure did not propagate real status");
failed = false;
try { child.execFileSync("/bin/sh", ["-c", "kill -TERM $$"], { stdio: "inherit" }); }
catch (error) { failed = error.status === null && error.signal === "SIGTERM"; }
if (!failed) throw new Error("child termination signal was lost");
console.log("OK home-tool inherited child execution");
