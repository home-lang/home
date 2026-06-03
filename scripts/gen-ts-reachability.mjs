#!/usr/bin/env node
// Classifies every `catalog-only` diagnostic code in
// docs/TS_DIAGNOSTIC_CODE_STATUS.md as either REACHABLE (the reference
// compiler, typescript-go, actually references the diagnostic in its own
// source — a genuine parity target Home should eventually emit) or DEAD
// (present only in the upstream message table, never referenced by tsgo —
// obsolete wording, e.g. the pre-Go TS6015 option descriptions superseded
// by TS6705, or codes that exist only in the classic tsc that tsgo dropped).
//
// This makes "100% faithful parity" well-defined: faithful parity means
// emitting the REACHABLE set, not chasing DEAD codes the reference compiler
// itself never produces. The reachability heuristic matches a code's
// catalogue key (its name minus the trailing `_<code>`) against production
// `diagnostics.<Name>` references anywhere in tsgo's `internal/` tree,
// excluding tests and the generated message table.
//
// Usage:  node scripts/gen-ts-reachability.mjs > docs/TS_DIAGNOSTIC_REACHABILITY.md
//   TSGO_ROOT overrides the reference checkout (default ~/Code/typescript-go).

import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const statusPath = path.join(root, "docs/TS_DIAGNOSTIC_CODE_STATUS.md");
const ref = process.env.TSGO_ROOT || path.join(process.env.HOME, "Code/typescript-go");
const refInternal = path.join(ref, "internal");

// --- catalog-only rows from the status ledger -----------------------------
const statusText = fs.readFileSync(statusPath, "utf8");
const catalogOnly = []; // { code, key, name, category }
for (const m of statusText.matchAll(
  /^\| (TS\d+) \| ([a-z]+) \| catalog-only \|[^|]*\| ([A-Za-z0-9_]+) \|$/gm,
)) {
  const key = m[3];
  catalogOnly.push({ code: m[1], category: m[2], key, name: key.replace(/_\d+$/, "") });
}

function walkGo(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walkGo(full, out);
    } else if (entry.isFile() &&
      entry.name.endsWith(".go") &&
      !entry.name.endsWith("_test.go") &&
      entry.name !== "diagnostics_generated.go") {
      out.push(full);
    }
  }
  return out;
}

// --- names referenced in tsgo source (excluding the generated table) ------
// Drop fully-commented lines (`// …diagnostics.X…`) so a reference that
// only survives in dead/commented code (e.g. TS5012) isn't counted as
// reachable. Inline trailing comments are rare for emission sites and are
// left in; this catches the common commented-out-statement case.
const referenced = new Set();
for (const file of walkGo(refInternal)) {
  const lines = fs.readFileSync(file, "utf8").split("\n");
  for (const line of lines) {
    if (/^\s*\/\//.test(line)) continue;
    for (const m of line.matchAll(/\bdiagnostics\.([A-Za-z0-9_]+)\b/g)) {
      referenced.add(m[1]);
    }
  }
}

// Go identifiers for generated diagnostics may be prefixed to avoid invalid
// or awkward exported names, while the catalogue key keeps the plain message
// name (for example TS6281 is referenced as
// diagnostics.X_package_json_has_a_peerDependencies_field).
const generatedText = fs.readFileSync(path.join(refInternal, "diagnostics/diagnostics_generated.go"), "utf8");
const generatedAliases = new Map();
for (const m of generatedText.matchAll(
  /^var\s+([A-Za-z0-9_]+)\s+=\s+&Message\{code:\s+(\d+),[^}]*key:\s+"([^"]+)"/gm,
)) {
  generatedAliases.set(m[3].replace(/_\d+$/, ""), m[1]);
}

function isReachable(name) {
  // Catalogue keys are truncated to a max length before the `_<code>`
  // suffix, so a referenced (untruncated) name may be longer than the key
  // name. Match on equality or referenced-name-startsWith-key-name.
  for (const r of referenced) if (r === name || r.startsWith(name)) return true;
  const alias = generatedAliases.get(name);
  if (alias && referenced.has(alias)) return true;
  return false;
}

const reachable = [];
const dead = [];
for (const row of catalogOnly) (isReachable(row.name) ? reachable : dead).push(row);

// --- range buckets for the reachable worklist -----------------------------
function bucket(code) {
  const n = Number(code.slice(2));
  if (n >= 90000) return "9xxxx — editor code-fix / refactor (language service)";
  if (n >= 7000 && n < 8000) return "7xxx — noImplicitAny / implicit-type family";
  if (n >= 6000 && n < 7000) return "6xxx — CLI / build / watch / resolution-trace messages";
  if (n >= 5000 && n < 6000) return "5xxx — tsconfig / build-option validation";
  if (n >= 4000 && n < 5000) return "4xxx — declaration-emit (privacy / serialization)";
  if (n >= 2000 && n < 4000) return "2xxx — checker / type engine";
  if (n >= 1000 && n < 2000) return "1xxx — parser / syntactic + program file-inclusion";
  return "other";
}
const byBucket = new Map();
for (const r of reachable) {
  const b = bucket(r.code);
  if (!byBucket.has(b)) byBucket.set(b, []);
  byBucket.get(b).push(r);
}

// --- emit markdown ---------------------------------------------------------
const out = [];
out.push("# TypeScript Diagnostic Reachability");
out.push("");
out.push("> Generated by `node scripts/gen-ts-reachability.mjs`. Do not hand-edit.");
out.push("");
out.push(
  "Splits the `catalog-only` rows of [TS_DIAGNOSTIC_CODE_STATUS.md](./TS_DIAGNOSTIC_CODE_STATUS.md)",
);
out.push(
  "into codes the reference compiler (typescript-go) **actually references in source**",
);
out.push(
  "(*reachable* — genuine parity targets) versus codes present only in the upstream",
);
out.push(
  "message table that tsgo never emits (*dead* — obsolete wording, test-only fixtures, or classic-tsc-only).",
);
out.push("");
out.push("**Faithful parity = emit the reachable set.** Dead codes correctly stay");
out.push("`catalog-only`; emitting them would diverge from the reference compiler.");
out.push("");
out.push("## Summary");
out.push("");
out.push("| Bucket | Count |");
out.push("| --- | ---: |");
out.push(`| catalog-only total | ${catalogOnly.length} |`);
out.push(`| reachable (parity targets) | ${reachable.length} |`);
out.push(`| dead in tsgo (leave catalog-only) | ${dead.length} |`);
out.push("");
out.push("## Reachable worklist by range");
out.push("");
out.push("| Range | Count |");
out.push("| --- | ---: |");
for (const [b, rows] of [...byBucket.entries()].sort((a, c) => c[1].length - a[1].length)) {
  out.push(`| ${b} | ${rows.length} |`);
}
out.push("");
for (const [b, rows] of [...byBucket.entries()].sort((a, c) => c[1].length - a[1].length)) {
  out.push(`### ${b} (${rows.length})`);
  out.push("");
  for (const r of rows.sort((x, y) => Number(x.code.slice(2)) - Number(y.code.slice(2)))) {
    out.push(`- ${r.code} \`${r.key}\``);
  }
  out.push("");
}
out.push("## Notes: heuristic false-positives & subsystem-gated clusters");
out.push("");
out.push("Some codes the heuristic marks *reachable* are blocked or effectively");
out.push("dead. Confirm against this list before picking one:");
out.push("");
out.push("- **Effectively dead despite a reference** — the diagnostic name appears");
out.push("  only inside a config struct literal whose consumer is dead/commented in");
out.push("  tsgo, so it is never emitted: **TS5078 / TS5079** (`Unknown_watch_option…`)");
out.push("  live in `watchOptionsDidYouMeanDiagnostics`, but tsgo's JSON `watchOptions`");
out.push("  parsing is commented out, so only TS5080 (its `OptionTypeMismatchDiagnostic`,");
out.push("  used on the command line) actually fires.");
out.push("- **`tsc --build` mode (not yet in Home)** — **TS5072 / TS5073 / TS5077**");
out.push("  (build-option parse errors) and **TS5093 / TS5094** (`--build`-only vs");
out.push("  non-`--build` option gating) require the project-references build");
out.push("  orchestrator. Implement `tsc -b` before these.");
out.push("- **CLI watch-flag typing** — **TS5080** (`Watch_option_0_requires_a_value_of_type_1`)");
out.push("  fires when a watch flag like `--watchFile` gets a wrong-typed value on the");
out.push("  command line; needs Home's arg parser to model the watch-option table + value");
out.push("  types (Home currently accepts unknown flags loosely).");
out.push("");
out.push("## Dead in tsgo (faithfully catalog-only)");
out.push("");
out.push(`${dead.length} codes. Listed for auditability; none should be \`emitted\` unless a production tsgo reference appears.`);
out.push("");
out.push("<details><summary>Show dead codes</summary>");
out.push("");
for (const r of dead.sort((x, y) => Number(x.code.slice(2)) - Number(y.code.slice(2)))) {
  out.push(`- ${r.code} \`${r.key}\``);
}
out.push("");
out.push("</details>");
out.push("");

process.stderr.write(
  `catalog-only ${catalogOnly.length} = reachable ${reachable.length} + dead ${dead.length}\n`,
);
process.stdout.write(out.join("\n"));
