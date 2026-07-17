#!/usr/bin/env node
// Generates packages/ts_cli/src/options_table.zig — a faithful port of
// tsgo's command-line option declarations (internal/tsoptions/decls*.go),
// joined against Home's diagnostic catalogue so each option carries the
// TSxxxx code of its `--help` description (and grouping category). This is
// the same model tsc uses: `--help` text is rendered from the options
// table's `description` diagnostics, not hand-written prose.
//
// Re-run after pulling new option decls from the reference compiler:
//   node scripts/gen-cli-options-table.mjs > packages/ts_cli/src/options_table.zig

import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const ref = process.env.TSGO_ROOT || path.join(root, "_submodules/typescript-go");
const catalogPath = path.join(root, "packages/ts_diagnostics/src/ts_diagnostic_codes.zig");

// ---- 1. Home catalogue: name (key minus trailing _<code>) -> code --------
const catalogText = fs.readFileSync(catalogPath, "utf8");
const catalogRe = /^\s*(\d+) => \.\{ \.code = \1, \.category = \.[a-z_]+, \.key = "([^"]+)", /gm;
// nameToCode maps the de-suffixed key to its code. Keys are truncated in the
// catalogue, so we record the (possibly truncated) name verbatim.
const catalogNames = []; // { name, code }
for (const m of catalogText.matchAll(catalogRe)) {
  const code = Number(m[1]);
  const key = m[2];
  const name = key.replace(/_\d+$/, "");
  catalogNames.push({ name, code });
}

// Resolve a tsgo diagnostic identifier (full, untruncated) to a Home code by
// finding the catalogue entry whose stored name is the longest prefix of it.
function codeFor(diagName) {
  let best = null;
  const normalizedDiagName = diagName.startsWith("X_") ? diagName.slice(2) : diagName;
  for (const c of catalogNames) {
    if (diagName === c.name || diagName.startsWith(c.name) ||
        normalizedDiagName === c.name || normalizedDiagName.startsWith(c.name)) {
      if (best === null || c.name.length > best.name.length) best = c;
    }
  }
  return best ? best.code : null;
}

// ---- 2. tsgo option declarations -----------------------------------------
function readEntries(file) {
  const full = path.join(ref, "internal/tsoptions", file);
  if (!fs.existsSync(full)) return [];
  const text = fs.readFileSync(full, "utf8");
  // Each option is a top-level `{ ... }` struct literal inside a slice. Match
  // brace-balanced blocks that contain a `Name:` field.
  const entries = [];
  const lines = text.split("\n");
  let buf = null;
  let depth = 0;
  for (const line of lines) {
    const opens = (line.match(/\{/g) || []).length;
    const closes = (line.match(/\}/g) || []).length;
    if (buf === null) {
      if (/^\s*\{\s*$/.test(line)) {
        buf = [];
        depth = 1;
        continue;
      }
    } else {
      depth += opens - closes;
      if (depth <= 0) {
        const block = buf.join("\n");
        if (/\bName:/.test(block)) entries.push(block);
        buf = null;
        continue;
      }
      buf.push(line);
    }
  }
  return entries;
}

function readStandaloneEntry(file, varName) {
  const full = path.join(ref, "internal/tsoptions", file);
  if (!fs.existsSync(full)) return null;
  const text = fs.readFileSync(full, "utf8");
  const start = text.indexOf(`var ${varName} = CommandLineOption{`);
  if (start < 0) return null;
  const open = text.indexOf("{", start);
  if (open < 0) return null;
  let depth = 0;
  for (let i = open; i < text.length; i++) {
    if (text[i] === "{") depth++;
    if (text[i] === "}") {
      depth--;
      if (depth === 0) return text.slice(open + 1, i);
    }
  }
  return null;
}

function field(block, name) {
  const m = block.match(new RegExp(`\\b${name}:\\s*("([^"]*)"|diagnostics\\.([A-Za-z0-9_]+)|[A-Za-z0-9_.]+)`));
  if (!m) return null;
  if (m[2] !== undefined && m[2] !== null && m[1].startsWith('"')) return { str: m[2] };
  if (m[3]) return { diag: m[3] };
  return { raw: m[1] };
}

function normalizeKind(kindF) {
  if (!kindF) return "";
  const raw = kindF.str ?? kindF.raw ?? "";
  return raw.replace(/^CommandLineOptionType/, "").replace(/^./, (c) => c.toLowerCase());
}

function readRefFile(file) {
  return fs.readFileSync(path.join(ref, "internal/tsoptions", file), "utf8");
}

function parseElementKinds() {
  const text = readRefFile("commandlineoption.go");
  const elements = new Map();
  const mapStart = text.indexOf("var commandLineOptionElements");
  const mapEnd = text.indexOf("// CommandLineOption.EnumMap()", mapStart);
  const body = mapStart >= 0 && mapEnd >= 0 ? text.slice(mapStart, mapEnd) : "";
  for (const m of body.matchAll(/"([^"]+)":\s*\{([\s\S]*?)\n\s*\},/g)) {
    const kindF = field(m[2], "Kind");
    const kind = normalizeKind(kindF);
    if (kind) elements.set(m[1], kind);
  }
  return elements;
}

function parseEnumOptionMaps() {
  const text = readRefFile("commandlineoption.go");
  const maps = new Map();
  const mapStart = text.indexOf("var commandLineOptionEnumMap");
  const mapEnd = text.indexOf("// CommandLineOption.DeprecatedKeys()", mapStart);
  const body = mapStart >= 0 && mapEnd >= 0 ? text.slice(mapStart, mapEnd) : "";
  for (const m of body.matchAll(/"([^"]+)":\s*([A-Za-z0-9_]+)/g)) {
    maps.set(m[1], m[2]);
  }
  return maps;
}

function parseDeprecatedKeys() {
  const text = readRefFile("commandlineoption.go");
  const deprecated = new Map();
  const mapStart = text.indexOf("var commandLineOptionDeprecated");
  const body = mapStart >= 0 ? text.slice(mapStart) : "";
  for (const m of body.matchAll(/"([^"]+)":\s*collections\.NewSetFromItems\(([^)]*)\)/g)) {
    const keys = new Set();
    for (const k of m[2].matchAll(/"([^"]+)"/g)) keys.add(k[1]);
    deprecated.set(m[1], keys);
  }
  return deprecated;
}

function parseEnumMapValues() {
  const text = readRefFile("enummaps.go");
  const values = new Map();
  for (const m of text.matchAll(/var\s+([A-Za-z0-9_]+)\s*=\s*collections\.NewOrderedMapFromList\(\[\]collections\.MapEntry\[string,\s*any\]\{\n([\s\S]*?)\n\}\)/g)) {
    const entries = [];
    for (const e of m[2].matchAll(/\{Key:\s*"([^"]+)",\s*Value:\s*([^}]+)\},/g)) {
      entries.push({ key: e[1], value: e[2].trim().replace(/,\s*$/, "") });
    }
    values.set(m[1], entries);
  }
  return values;
}

const elementKinds = parseElementKinds();
const enumOptionMaps = parseEnumOptionMaps();
const deprecatedKeys = parseDeprecatedKeys();
const enumMapValues = parseEnumMapValues();

function enumPossibleValues(optionName) {
  const mapName = enumOptionMaps.get(optionName);
  const entries = mapName ? enumMapValues.get(mapName) : null;
  if (!entries) return "";
  const deprecated = deprecatedKeys.get(optionName);
  const grouped = new Map();
  for (const entry of entries) {
    if (deprecated && deprecated.has(entry.key)) continue;
    if (!grouped.has(entry.value)) grouped.set(entry.value, []);
    grouped.get(entry.value).push(entry.key);
  }
  return [...grouped.values()].map((keys) => keys.join("/")).join(", ");
}

function possibleValues(optionName, kind) {
  switch (kind) {
    case "string":
    case "number":
    case "boolean":
      return kind;
    case "list": {
      const elementKind = elementKinds.get(optionName);
      if (elementKind === "enum") return enumPossibleValues(optionName);
      return elementKind || "";
    }
    case "enum":
      return enumPossibleValues(optionName);
    default:
      return "";
  }
}

const seen = new Set();
const options = [];
function addOptionBlock(block) {
  if (!block) return;
  const nameF = field(block, "Name");
  if (!nameF || !nameF.str) return;
  const name = nameF.str;
  const shortF = field(block, "ShortName");
  const short = shortF && shortF.str ? shortF.str : "";
  const descF = field(block, "Description");
  const catF = field(block, "Category");
  const defaultF = field(block, "DefaultValueDescription");
  const kind = normalizeKind(field(block, "Kind"));
  const simplified = /ShowInSimplifiedHelpView:\s*true/.test(block);
  const cmdOnly = /IsCommandLineOnly:\s*true/.test(block);
  const descCode = descF && descF.diag ? codeFor(descF.diag) : null;
  const catCode = catF && catF.diag ? codeFor(catF.diag) : null;
  const defaultCode = defaultF && defaultF.diag ? codeFor(defaultF.diag) : null;
  // Dedup on (name, short); the `?`-aliased help entry has no description.
  const dkey = name + "\0" + short;
  if (seen.has(dkey)) return;
  seen.add(dkey);
  options.push({ name, short, descCode, catCode, simplified, cmdOnly,
    descDiag: descF && descF.diag ? descF.diag : null,
    defaultDiag: defaultF && defaultF.diag ? defaultF.diag : null,
    defaultCode,
    kind,
    values: possibleValues(name, kind) });
}

for (const file of ["declscompiler.go", "declswatch.go", "declsbuild.go"]) {
  if (file === "declsbuild.go") addOptionBlock(readStandaloneEntry(file, "TscBuildOption"));
  for (const block of readEntries(file)) {
    addOptionBlock(block);
  }
}

// ---- 3. Emit Zig ----------------------------------------------------------
function zstr(s) { return '"' + s.replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"'; }
let missing = 0;
const out = [];
out.push("//! GENERATED by scripts/gen-cli-options-table.mjs — do not edit by hand.");
out.push("//!");
out.push("//! Faithful port of tsgo's command-line option declarations");
out.push("//! (internal/tsoptions/decls*.go). Each row carries the TSxxxx code of");
out.push("//! its `--help` description and grouping category, so `home tsc --help`");
out.push("//! renders from the diagnostic catalogue exactly as tsc does.");
out.push("");
out.push('const std = @import("std");');
out.push("");
out.push("pub const OptionDecl = struct {");
out.push("    name: []const u8,");
out.push("    short: []const u8 = \"\",");
out.push("    /// TSxxxx code of the option's `--help` description, or 0 if the");
out.push("    /// upstream decl carries no description (e.g. the `-?` help alias).");
out.push("    code: u32 = 0,");
out.push("    /// TSxxxx code of the option's `--help` category header, or 0.");
out.push("    category: u32 = 0,");
out.push("    /// TSxxxx code of the option's diagnostic-backed default-value text, or 0.");
out.push("    default_code: u32 = 0,");
out.push("    /// Upstream command-line option kind.");
out.push("    kind: []const u8 = \"\",");
out.push("    /// Rendered possible value/type text for `--help` additional info.");
out.push("    possible_values: []const u8 = \"\",");
out.push("    /// Shown in the default (non-`--all`) `--help` view.");
out.push("    simplified: bool = false,");
out.push("    /// Only valid on the command line (never in tsconfig.json).");
out.push("    command_line_only: bool = false,");
out.push("};");
out.push("");
out.push("pub const all_options = [_]OptionDecl{");
for (const o of options) {
  if (o.descDiag && o.descCode === null) missing++;
  if (o.defaultDiag && o.defaultCode === null) missing++;
  const parts = [`.name = ${zstr(o.name)}`];
  if (o.short) parts.push(`.short = ${zstr(o.short)}`);
  if (o.descCode) parts.push(`.code = ${o.descCode}`);
  if (o.catCode) parts.push(`.category = ${o.catCode}`);
  if (o.defaultCode) parts.push(`.default_code = ${o.defaultCode}`);
  if (o.kind) parts.push(`.kind = ${zstr(o.kind)}`);
  if (o.values) parts.push(`.possible_values = ${zstr(o.values)}`);
  if (o.simplified) parts.push(`.simplified = true`);
  if (o.cmdOnly) parts.push(`.command_line_only = true`);
  out.push(`    .{ ${parts.join(", ")} },`);
}
out.push("};");
out.push("");

process.stderr.write(`options: ${options.length}, with description code: ${options.filter(o => o.descCode).length}, unresolved descriptions: ${missing}\n`);
process.stdout.write(out.join("\n"));
