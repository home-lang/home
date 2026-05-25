#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const catalogPath = path.join(root, "packages/ts_diagnostics/src/ts_diagnostic_codes.zig");
const checkerPath = path.join(root, "packages/ts_checker/src/check.zig");
const outputPath = path.join(root, "docs/TS_DIAGNOSTIC_CODE_STATUS.md");

function read(file) {
  return fs.readFileSync(file, "utf8");
}

function walk(dir, out = []) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === ".git" || entry.name === ".zig-cache" || entry.name === "zig-cache" || entry.name === "node_modules") continue;
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      walk(full, out);
    } else if (entry.isFile() && /\.(zig|md|mjs|js|ts|tsx|json|toml)$/.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

function rel(file) {
  return path.relative(root, file);
}

function lineOf(text, index) {
  let line = 1;
  for (let i = 0; i < index; i++) if (text.charCodeAt(i) === 10) line++;
  return line;
}

function escapeCell(s) {
  return String(s).replaceAll("|", "\\|").replace(/\s+/g, " ").trim();
}

const catalogText = read(catalogPath);
const catalog = [];
const catalogRe = /^\s*(\d+) => \.\{ \.code = \1, \.category = \.([a-z_]+), \.key = "([^"]+)", \.message = "((?:\\.|[^"])*)" \},/gm;
for (const m of catalogText.matchAll(catalogRe)) {
  catalog.push({
    code: Number(m[1]),
    category: m[2],
    key: m[3],
    message: m[4],
  });
}

const checkerText = fs.existsSync(checkerPath) ? read(checkerPath) : "";
const tsCodeNames = new Map();
const constRe = /^\s*pub const ([A-Za-z0-9_]+): u32 = (\d+);/gm;
for (const m of checkerText.matchAll(constRe)) {
  tsCodeNames.set(m[1], Number(m[2]));
}

const byCode = new Map(catalog.map((entry) => [entry.code, {
  ...entry,
  declared: false,
  production: [],
  tests: [],
}]));

for (const code of tsCodeNames.values()) {
  const entry = byCode.get(code);
  if (entry) entry.declared = true;
}

const scanRoots = [
  "build.zig",
  "scripts",
  "packages/ts_checker",
  "packages/ts_parser",
  "packages/ts_driver",
  "packages/ts_conformance",
  "packages/ts_program",
  "packages/ts_resolver",
  "packages/ts_emit",
  "packages/ts_cli",
  "packages/ts_lsp",
  "packages/ts_lsp_server",
  "packages/tsconfig",
];

const sourceFiles = scanRoots.flatMap((scanRoot) => {
  const full = path.join(root, scanRoot);
  if (!fs.existsSync(full)) return [];
  if (fs.statSync(full).isDirectory()) return walk(full);
  return [full];
}).filter((file) => {
  const r = rel(file);
  if (r === "packages/ts_diagnostics/src/ts_diagnostic_codes.zig") return false;
  if (r === "docs/TS_DIAGNOSTIC_CODE_STATUS.md") return false;
  if (r.startsWith("pantry/")) return false;
  if (r.startsWith(".claude/")) return false;
  return true;
});

function addRef(code, file, line, kind) {
  const entry = byCode.get(code);
  if (!entry) return;
  const bucket = kind === "test" ? entry.tests : entry.production;
  const ref = `${rel(file)}:${line}`;
  if (!bucket.includes(ref)) bucket.push(ref);
}

for (const file of sourceFiles) {
  const text = read(file);
  const fileIsTest = /(^|\/)(tests?|fixtures?)\//.test(rel(file));
  const firstTestIndex = text.search(/^test "/m);
  const firstTestLine = firstTestIndex >= 0 ? lineOf(text, firstTestIndex) : Number.POSITIVE_INFINITY;
  const kindAtLine = (line) => (fileIsTest || line >= firstTestLine) ? "test" : "production";

  for (const m of text.matchAll(/\bTsCodes\.([A-Za-z0-9_]+)\b/g)) {
    const code = tsCodeNames.get(m[1]);
    const line = lineOf(text, m.index);
    if (code) addRef(code, file, line, kindAtLine(line));
  }

  for (const m of text.matchAll(/(?:\.code\s*=\s*|reportCodeAt\([^,\n]+,[^,\n]+,\s*|reportCodeAtWithSpan\([^,\n]+,[^,\n]+,[^,\n]+,\s*|reportCodeWithSpanAt\([^,\n]+,[^,\n]+,\s*|reportAt\([^,\n]+,[^,\n]+,\s*|appendDriverDiagnostic\([^,\n]+,[^,\n]+,[^,\n]+,\s*)(\d{4,5})\b/g)) {
    const line = lineOf(text, m.index);
    addRef(Number(m[1]), file, line, kindAtLine(line));
  }

  // Emission helpers that pass the code as a non-literal-positional argument
  // (e.g. `reportCodeAt(a, b, if (kind == .kw_in) 1091 else 1188, msg)`, or a
  // helper with extra leading args) are missed by the strict positional regex
  // above. Scan each line that invokes a diagnostic-emission helper (or sets a
  // `.code` field) and credit every 4-5 digit number on that line that is a
  // known catalog code. Scoping to emission-helper lines keeps incidental
  // numbers (line offsets, magic constants) from being mis-credited.
  // Emissions live only in Zig source; restricting this liberal numeric
  // pass to `.zig` avoids crediting example codes in scripts/docs/comments
  // (e.g. this generator's own description text).
  const emitLineRe = /\b(?:reportCodeAt|reportCodeAtWithSpan|reportCodeWithSpanAt|reportAt|reportCode|reportCodeOnce|appendDriverDiagnostic)\s*\(|\.code\s*=/;
  const lineList = file.endsWith(".zig") ? text.split("\n") : [];
  for (let i = 0; i < lineList.length; i++) {
    if (!emitLineRe.test(lineList[i])) continue;
    for (const m of lineList[i].matchAll(/\b(\d{4,5})\b/g)) {
      const code = Number(m[1]);
      if (byCode.has(code)) addRef(code, file, i + 1, kindAtLine(i + 1));
    }
    const window = lineList.slice(i, Math.min(i + 8, lineList.length)).join("\n");
    for (const m of window.matchAll(/\b(\d{4,5})\b/g)) {
      const code = Number(m[1]);
      if (!byCode.has(code)) continue;
      const before = window.slice(0, m.index);
      const offset = (before.match(/\n/g) || []).length;
      addRef(code, file, i + offset + 1, kindAtLine(i + offset + 1));
    }
  }
}

const counts = {
  emitted: 0,
  declared: 0,
  testedOnly: 0,
  catalogOnly: 0,
};

function status(entry) {
  if (entry.production.length > 0) {
    counts.emitted++;
    return "emitted";
  }
  if (entry.declared) {
    counts.declared++;
    return "declared";
  }
  if (entry.tests.length > 0) {
    counts.testedOnly++;
    return "tested-only";
  }
  counts.catalogOnly++;
  return "catalog-only";
}

const rows = catalog.map((catalogEntry) => {
  const entry = byCode.get(catalogEntry.code);
  const st = status(entry);
  const refs = [...entry.production, ...entry.tests].slice(0, 3).join("<br>");
  return `| TS${entry.code} | ${entry.category} | ${st} | ${refs || ""} | ${escapeCell(entry.key)} |`;
});

const generatedAt = new Date().toISOString().slice(0, 10);
const markdown = `# TypeScript Diagnostic Code Status

> Generated by \`node scripts/gen-ts-diagnostic-status.mjs\` from \`packages/ts_diagnostics/src/ts_diagnostic_codes.zig\`.
> Last generated: ${generatedAt}.

This ledger tracks every upstream \`TSxxxx\` diagnostic code known to Home's generated TypeScript diagnostic catalogue and whether Home currently references it in implementation or tests.

Status meanings:

- \`emitted\`: referenced from production Home source outside the generated catalogue.
- \`declared\`: declared in a local code enum/table but no production emission site was found by the scanner.
- \`tested-only\`: referenced only from test code or test fixtures.
- \`catalog-only\`: present in the upstream TypeScript catalogue but not yet referenced by Home source.

This is a scanner-generated code-coverage ledger, not a proof of exact parity. Documentation references are intentionally excluded from status classification so coordination notes cannot make a code look implemented. Exact wording, ordering, spans, related information, and fixture pass/fail status remain tracked by [TS_PARITY_PLAN.md](./TS_PARITY_PLAN.md) and the exact conformance runners.

## Multi-Agent Usage

- Pick a narrow, non-overlapping row or small cluster before editing. \`catalog-only\`, \`declared\`, and \`tested-only\` rows are good discovery targets, but every change still needs upstream TypeScript source/baseline verification.
- Claim active work in [TS_PARITY_PLAN.md](./TS_PARITY_PLAN.md) when a task will take more than a quick local patch, and keep write scopes disjoint across agents wherever possible.
- Do not hand-edit status rows. After adding or moving diagnostics, run \`node scripts/gen-ts-diagnostic-status.mjs\` so references and counts are regenerated consistently.
- A row becoming \`emitted\` only means Home has a production reference to that code. Faithful parity still requires focused unit coverage plus exact TypeScript fixture verification, with the command and pass count recorded in the parity plan.
- When closing a code, prefer the smallest faithful semantic implementation over fixture-specific wording shims; preserve upstream diagnostic category, message, anchor/span behavior, ordering, and related information where Home models it.

## Summary

| Status | Count |
| --- | ---: |
| emitted | ${counts.emitted} |
| declared | ${counts.declared} |
| tested-only | ${counts.testedOnly} |
| catalog-only | ${counts.catalogOnly} |
| total upstream codes | ${catalog.length} |

## Codes

| Code | Category | Home status | Sample Home references | Upstream key |
| --- | --- | --- | --- | --- |
${rows.join("\n")}
`;

fs.mkdirSync(path.dirname(outputPath), { recursive: true });
fs.writeFileSync(outputPath, markdown);
