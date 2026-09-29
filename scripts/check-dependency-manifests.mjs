#!/usr/bin/env bun

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const root = process.argv[2] ? resolve(process.argv[2]) : resolve(import.meta.dir, "..");
const readJson = (name) => Bun.JSONC.parse(readFileSync(resolve(root, name), "utf8"));

const packageManifest = readJson("package.json");
const pantryManifest = readJson("pantry.json");
const bunLock = readJson("bun.lock");
const pantryLock = readJson("pantry.lock");
const sections = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"];

function dependencies(manifest) {
  const entries = [];
  for (const section of sections) {
    for (const [name, version] of Object.entries(manifest[section] ?? {})) {
      entries.push({ name, section, version });
    }
  }
  return entries;
}

const problems = [];
const npmDependencies = dependencies(packageManifest);
const pantryDependencies = dependencies(pantryManifest);
const npmByName = new Map(npmDependencies.map((dependency) => [dependency.name, dependency]));

for (const dependency of pantryDependencies) {
  const npmDependency = npmByName.get(dependency.name);
  if (npmDependency) {
    problems.push(
      `${dependency.name} is owned by both package.json ${npmDependency.section} and pantry.json ${dependency.section}`,
    );
  }
}

const lockedNpmRoot = bunLock.workspaces?.[""];
if (!lockedNpmRoot) {
  problems.push('bun.lock has no root workspace entry (workspaces[""])');
} else {
  for (const section of sections) {
    const declared = packageManifest[section] ?? {};
    const locked = lockedNpmRoot[section] ?? {};
    const names = new Set([...Object.keys(declared), ...Object.keys(locked)]);
    for (const name of [...names].sort()) {
      if (!(name in declared)) {
        problems.push(`bun.lock still contains removed ${section} entry ${name}`);
      } else if (!(name in locked)) {
        problems.push(`bun.lock is missing package.json ${section} entry ${name}`);
      } else if (declared[name] !== locked[name]) {
        problems.push(
          `bun.lock records ${name}@${locked[name]} but package.json declares ${declared[name]}`,
        );
      }
    }
  }
}

for (const [key, dependency] of Object.entries(pantryLock.packages ?? {})) {
  if (dependency.source === "npm") {
    problems.push(
      `pantry.lock entry ${key} comes from npm; declare npm packages only in package.json`,
    );
  }
}

if (problems.length > 0) {
  console.error("Dependency manifest policy failed:");
  for (const problem of problems) console.error(`  - ${problem}`);
  process.exit(1);
}

console.log(
  `Dependency manifests are consistent (${npmDependencies.length} npm, ${pantryDependencies.length} Pantry).`,
);
