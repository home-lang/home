#!/usr/bin/env bun

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { relative, resolve, sep } from "node:path";

function normalizedRelativePath(root, file) {
  return relative(root, file).split(sep).join("/");
}

function htmlFilesBelow(directory) {
  const files = [];
  if (!existsSync(directory)) return files;

  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...htmlFilesBelow(path));
    } else if (entry.isFile() && entry.name.endsWith(".html")) {
      files.push(path);
    }
  }

  return files;
}

function decodeHtml(text) {
  return text.replaceAll(/&(#x[0-9a-f]+|#\d+|amp|apos|gt|lt|quot);/gi, (entity, code) => {
    const normalized = code.toLowerCase();
    if (normalized === "amp") return "&";
    if (normalized === "apos") return "'";
    if (normalized === "gt") return ">";
    if (normalized === "lt") return "<";
    if (normalized === "quot") return '"';
    if (normalized.startsWith("#x")) {
      return String.fromCodePoint(Number.parseInt(normalized.slice(2), 16));
    }
    return String.fromCodePoint(Number.parseInt(normalized.slice(1), 10));
  });
}

function normalizeText(text) {
  return decodeHtml(text).replaceAll(/\s+/g, " ").trim();
}

function parseAttributes(tag) {
  const attributes = new Map();
  const pattern = /\b([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/g;

  for (const match of tag.matchAll(pattern)) {
    attributes.set(match[1].toLowerCase(), match[2] ?? match[3] ?? "");
  }

  return attributes;
}

function tags(html, name) {
  const pattern = new RegExp(`<${name}\\b[^>]*>`, "gi");
  return [...html.matchAll(pattern)].map((match) => parseAttributes(match[0]));
}

function metaValues(html, selector, expected) {
  return tags(html, "meta")
    .filter((attributes) => attributes.get(selector)?.toLowerCase() === expected)
    .map((attributes) => attributes.get("content") ?? "");
}

function canonicalValues(html) {
  return tags(html, "link")
    .filter((attributes) =>
      (attributes.get("rel") ?? "")
        .toLowerCase()
        .split(/\s+/)
        .includes("canonical"),
    )
    .map((attributes) => attributes.get("href") ?? "");
}

function titleValues(html) {
  return [...html.matchAll(/<title\b[^>]*>([\s\S]*?)<\/title>/gi)].map((match) => match[1]);
}

function requireOne(values, label, file, violations) {
  if (values.length !== 1) {
    violations.push({ file, message: `expected exactly one ${label}, found ${values.length}` });
    return null;
  }

  const value = normalizeText(values[0]);
  if (value.length === 0) {
    violations.push({ file, message: `${label} must not be empty` });
    return null;
  }

  return value;
}

function requireHomeUrl(value, label, file, violations) {
  if (value === null) return;

  try {
    const url = new URL(value);
    if (url.protocol !== "https:" || url.hostname !== "home-lang.org") {
      violations.push({ file, message: `${label} must use https://home-lang.org` });
    }
  } catch {
    violations.push({ file, message: `${label} is not a valid absolute URL` });
  }
}

export function auditDocsMetadata(directory) {
  const root = resolve(directory);
  const files = htmlFilesBelow(root).sort();
  const violations = [];
  const titles = new Map();
  const canonicals = new Map();
  const descriptions = new Set();

  if (files.length === 0) {
    violations.push({
      file: normalizedRelativePath(process.cwd(), root) || root,
      message: "contains no generated HTML; run `bun run build:docs` first",
    });
  }

  for (const file of files) {
    const display = normalizedRelativePath(root, file);
    const html = readFileSync(file, "utf8");
    const title = requireOne(titleValues(html), "title", display, violations);
    const description = requireOne(
      metaValues(html, "name", "description"),
      "meta description",
      display,
      violations,
    );
    const canonical = requireOne(canonicalValues(html), "canonical link", display, violations);
    const ogType = requireOne(
      metaValues(html, "property", "og:type"),
      "og:type",
      display,
      violations,
    );
    const ogUrl = requireOne(
      metaValues(html, "property", "og:url"),
      "og:url",
      display,
      violations,
    );
    const ogTitle = requireOne(
      metaValues(html, "property", "og:title"),
      "og:title",
      display,
      violations,
    );
    const ogDescription = requireOne(
      metaValues(html, "property", "og:description"),
      "og:description",
      display,
      violations,
    );
    const ogImage = requireOne(
      metaValues(html, "property", "og:image"),
      "og:image",
      display,
      violations,
    );
    const twitterCard = requireOne(
      metaValues(html, "name", "twitter:card"),
      "twitter:card",
      display,
      violations,
    );
    const twitterTitle = requireOne(
      metaValues(html, "name", "twitter:title"),
      "twitter:title",
      display,
      violations,
    );
    const twitterDescription = requireOne(
      metaValues(html, "name", "twitter:description"),
      "twitter:description",
      display,
      violations,
    );
    const twitterImage = requireOne(
      metaValues(html, "name", "twitter:image"),
      "twitter:image",
      display,
      violations,
    );

    requireHomeUrl(canonical, "canonical link", display, violations);
    requireHomeUrl(ogUrl, "og:url", display, violations);
    requireHomeUrl(ogImage, "og:image", display, violations);
    requireHomeUrl(twitterImage, "twitter:image", display, violations);

    if (canonical !== null && ogUrl !== null && canonical !== ogUrl) {
      violations.push({ file: display, message: "canonical link and og:url differ" });
    }
    if (description !== null && ogDescription !== null && description !== ogDescription) {
      violations.push({ file: display, message: "meta and Open Graph descriptions differ" });
    }
    if (
      description !== null &&
      twitterDescription !== null &&
      description !== twitterDescription
    ) {
      violations.push({ file: display, message: "meta and Twitter descriptions differ" });
    }
    if (ogTitle !== null && twitterTitle !== null && ogTitle !== twitterTitle) {
      violations.push({ file: display, message: "Open Graph and Twitter titles differ" });
    }
    if (title !== null && ogTitle !== null && title !== ogTitle && title !== `${ogTitle} | Home`) {
      violations.push({ file: display, message: "document and social titles differ" });
    }
    if (ogImage !== null && twitterImage !== null && ogImage !== twitterImage) {
      violations.push({ file: display, message: "Open Graph and Twitter images differ" });
    }
    if (ogType !== null && ogType !== "website") {
      violations.push({ file: display, message: `og:type must be website, found ${ogType}` });
    }
    if (twitterCard !== null && twitterCard !== "summary_large_image") {
      violations.push({
        file: display,
        message: `twitter:card must be summary_large_image, found ${twitterCard}`,
      });
    }

    if (title !== null) {
      const existing = titles.get(title);
      if (existing) {
        violations.push({ file: display, message: `title duplicates ${existing}: ${title}` });
      } else {
        titles.set(title, display);
      }
    }

    if (canonical !== null) {
      const existing = canonicals.get(canonical);
      if (existing) {
        violations.push({
          file: display,
          message: `canonical URL duplicates ${existing}: ${canonical}`,
        });
      } else {
        canonicals.set(canonical, display);
      }
    }

    if (description !== null) descriptions.add(description);
  }

  return {
    canonicals,
    descriptions,
    files,
    titles,
    violations,
  };
}

if (import.meta.main) {
  const directory = process.argv[2]
    ? resolve(process.argv[2])
    : resolve(import.meta.dir, "../dist/.bunpress");
  const result = auditDocsMetadata(directory);

  if (result.violations.length > 0) {
    console.error("Documentation metadata policy failed:");
    for (const violation of result.violations) {
      console.error(`  - ${violation.file}: ${violation.message}`);
    }
    process.exit(1);
  }

  console.log(
    `Documentation metadata is complete (${result.files.length} pages, ` +
      `${result.titles.size} unique titles, ${result.canonicals.size} unique canonicals, ` +
      `${result.descriptions.size} distinct descriptions).`,
  );
}
