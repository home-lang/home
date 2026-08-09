import { readFileSync, writeFileSync } from "node:fs";

const sourcePath = "_submodules/typescript-go/internal/stringutil/js_case_generated.go";
const outputPath = "packages/ts_checker/src/unicode_case.zig";
const source = readFileSync(sourcePath, "utf8");

function decodeGoString(raw) {
  let result = "";
  for (let i = 0; i < raw.length; i++) {
    if (raw[i] !== "\\") {
      result += raw[i];
      continue;
    }
    const kind = raw[++i];
    if (kind === "u" || kind === "U") {
      const width = kind === "u" ? 4 : 8;
      const codepoint = Number.parseInt(raw.slice(i + 1, i + 1 + width), 16);
      result += String.fromCodePoint(codepoint);
      i += width;
    } else if (kind === "n") {
      result += "\n";
    } else if (kind === "r") {
      result += "\r";
    } else if (kind === "t") {
      result += "\t";
    } else {
      result += kind;
    }
  }
  return result;
}

function zigBytes(value) {
  return `"${[...Buffer.from(value, "utf8")].map(byte => `\\x${byte.toString(16).padStart(2, "0")}`).join("")}"`;
}

const mappingBlock = source.slice(
  source.indexOf("var specialCasingMappings"),
  source.indexOf("var unicodeCasedRanges"),
);
const mappings = [];
for (const line of mappingBlock.split("\n")) {
  const head = line.match(/^\s*0x([0-9A-F]+):\s*\{(.*)\},$/);
  if (!head) continue;
  const fields = head[2];
  const lower = fields.match(/lower:\s*"([^"]*)"/)?.[1] ?? "";
  const upper = fields.match(/upper:\s*"([^"]*)"/)?.[1] ?? "";
  const conditional = fields.match(/conditionalLower:\s*"([^"]*)"/)?.[1] ?? "";
  mappings.push({
    codepoint: head[1],
    lower: decodeGoString(lower),
    upper: decodeGoString(upper),
    conditional: decodeGoString(conditional),
    finalSigma: fields.includes("specialCasingConditionFinalSigma"),
  });
}

function parseRanges(name, nextName) {
  const start = source.indexOf(`var ${name}`);
  const end = nextName ? source.indexOf(`var ${nextName}`, start) : source.length;
  const block = source.slice(start, end);
  return [...block.matchAll(/\{0x([0-9A-F]+),\s*0x([0-9A-F]+),\s*(\d+)\}/g)].map(match => ({
    lo: match[1],
    hi: match[2],
    stride: match[3],
  }));
}

const cased = parseRanges("unicodeCasedRanges", "unicodeCaseIgnorableRanges");
const ignorable = parseRanges("unicodeCaseIgnorableRanges");

const lines = [];
lines.push("// Generated from tsgo Unicode 15.1 ECMAScript casing data. DO NOT EDIT.");
lines.push("const std = @import(\"std\");");
lines.push("");
lines.push("pub const Kind = enum { lowercase, uppercase, capitalize, uncapitalize };", "");
lines.push("const Mapping = struct { codepoint: u21, lower: []const u8, upper: []const u8, conditional_lower: []const u8, final_sigma: bool };", "");
lines.push("const mappings = [_]Mapping{");
for (const mapping of mappings) {
  lines.push(`    .{ .codepoint = 0x${mapping.codepoint}, .lower = ${zigBytes(mapping.lower)}, .upper = ${zigBytes(mapping.upper)}, .conditional_lower = ${zigBytes(mapping.conditional)}, .final_sigma = ${mapping.finalSigma} },`);
}
lines.push("};", "");
lines.push("const Range = struct { lo: u21, hi: u21, stride: u21 };", "");
for (const [name, ranges] of [["cased_ranges", cased], ["case_ignorable_ranges", ignorable]]) {
  lines.push(`const ${name} = [_]Range{`);
  for (const range of ranges) lines.push(`    .{ .lo = 0x${range.lo}, .hi = 0x${range.hi}, .stride = ${range.stride} },`);
  lines.push("};", "");
}
lines.push(readFileSync("scripts/unicode-case-runtime.zig", "utf8").trimEnd(), "");
writeFileSync(outputPath, `${lines.join("\n")}\n`);
