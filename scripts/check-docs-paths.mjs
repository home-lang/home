#!/usr/bin/env bun

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { extname, relative, resolve, sep } from "node:path";

const allowedPlaceholderUsers = new Set(["...", "user", "username"]);
const documentationExtensions = new Set([".json", ".md"]);
const posixHomePattern = /(\/(?:Users|home)\/([A-Za-z0-9._-]+))(?=\/|\s|$|["'`<>),.;:])/g;
const windowsHomePattern = /([A-Za-z]:\\Users\\([A-Za-z0-9._-]+))(?=\\|\s|$|["'`<>),.;:])/g;

function hasAbsoluteBoundary(line, index) {
  if (index === 0) return true;
  return !/[A-Za-z0-9_.-]/.test(line[index - 1]);
}

function normalizedRelativePath(root, file) {
  return relative(root, file).split(sep).join("/");
}

function documentationFilesBelow(directory) {
  const files = [];
  if (!existsSync(directory)) return files;

  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...documentationFilesBelow(path));
    } else if (entry.isFile() && documentationExtensions.has(extname(entry.name))) {
      files.push(path);
    }
  }

  return files;
}

export function findPersonalHomePaths(text, file = "<input>") {
  const violations = [];
  const lines = text.split(/\r?\n/);

  for (const [lineIndex, line] of lines.entries()) {
    for (const pattern of [posixHomePattern, windowsHomePattern]) {
      pattern.lastIndex = 0;
      for (const match of line.matchAll(pattern)) {
        if (!hasAbsoluteBoundary(line, match.index)) continue;
        if (allowedPlaceholderUsers.has(match[2].toLowerCase())) continue;
        violations.push({
          column: match.index + 1,
          file,
          line: lineIndex + 1,
          path: match[1],
        });
      }
    }
  }

  return violations;
}

export function checkDocsPaths(root) {
  const files = documentationFilesBelow(resolve(root, "docs"));
  const readme = resolve(root, "README.md");
  if (existsSync(readme)) files.push(readme);
  files.sort();

  const violations = [];
  for (const file of files) {
    const display = normalizedRelativePath(root, file);
    violations.push(...findPersonalHomePaths(readFileSync(file, "utf8"), display));
  }

  return { files, violations };
}

if (import.meta.main) {
  const root = process.argv[2] ? resolve(process.argv[2]) : resolve(import.meta.dir, "..");
  const { files, violations } = checkDocsPaths(root);

  if (violations.length > 0) {
    console.error("Documentation path policy failed:");
    for (const violation of violations) {
      console.error(
        `  - ${violation.file}:${violation.line}:${violation.column} contains ${violation.path}`,
      );
    }
    console.error(
      "Use a repository-relative path, <repo>, or ~/Code/...; /Users/username and /home/user remain valid placeholders.",
    );
    process.exit(1);
  }

  console.log(`Documentation paths are portable (${files.length} Markdown/JSON files checked).`);
}
