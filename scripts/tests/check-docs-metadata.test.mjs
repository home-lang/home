import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { auditDocsMetadata } from "../check-docs-metadata.mjs";

function validPage({ description, path, title }) {
  const url = `https://home-lang.org${path}`;
  return `<!doctype html>
<html>
<head>
  <title>${title} | Home</title>
  <meta content="${description}" name="description">
  <link href="${url}" rel="canonical">
  <meta content="website" property="og:type">
  <meta content="${url}" property="og:url">
  <meta content="${title}" property="og:title">
  <meta content="${description}" property="og:description">
  <meta content="https://home-lang.org/og.png" property="og:image">
  <meta content="summary_large_image" name="twitter:card">
  <meta content="${title}" name="twitter:title">
  <meta content="${description}" name="twitter:description">
  <meta content="https://home-lang.org/og.png" name="twitter:image">
</head>
</html>`;
}

function withTemporarySite(run) {
  const temporary = mkdtempSync(join(tmpdir(), "home-doc-metadata-"));
  try {
    run(temporary);
  } finally {
    rmSync(temporary, { force: true, recursive: true });
  }
}

describe("documentation metadata policy", () => {
  test("accepts complete metadata regardless of attribute order", () => {
    withTemporarySite((site) => {
      mkdirSync(join(site, "docs"));
      writeFileSync(
        join(site, "index.html"),
        validPage({ description: "Home page", path: "/", title: "Home" }),
      );
      writeFileSync(
        join(site, "docs", "index.html"),
        validPage({ description: "Documentation", path: "/docs", title: "Documentation" }),
      );

      const result = auditDocsMetadata(site);
      expect(result.violations).toEqual([]);
      expect(result.files).toHaveLength(2);
      expect(result.titles.size).toBe(2);
      expect(result.canonicals.size).toBe(2);
      expect(result.descriptions.size).toBe(2);
    });
  });

  test("rejects missing and inconsistent social metadata", () => {
    withTemporarySite((site) => {
      const html = validPage({
        description: "Reference",
        path: "/docs/reference",
        title: "Reference",
      })
        .replace('<meta content="Reference" name="twitter:description">', "")
        .replace(
          '<meta content="https://home-lang.org/docs/reference" property="og:url">',
          '<meta content="https://home-lang.org/docs/other" property="og:url">',
        );
      writeFileSync(join(site, "index.html"), html);

      const messages = auditDocsMetadata(site).violations.map((violation) => violation.message);
      expect(messages).toContain("expected exactly one twitter:description, found 0");
      expect(messages).toContain("canonical link and og:url differ");
    });
  });

  test("rejects duplicate page titles and canonical URLs", () => {
    withTemporarySite((site) => {
      mkdirSync(join(site, "copy"));
      const html = validPage({ description: "Same", path: "/same", title: "Same" });
      writeFileSync(join(site, "index.html"), html);
      writeFileSync(join(site, "copy", "index.html"), html);

      const messages = auditDocsMetadata(site).violations.map((violation) => violation.message);
      expect(messages.some((message) => message.startsWith("title duplicates"))).toBe(true);
      expect(messages.some((message) => message.startsWith("canonical URL duplicates"))).toBe(
        true,
      );
    });
  });

  test("fails the command when generated HTML is absent", () => {
    withTemporarySite((site) => {
      const command = Bun.spawnSync([
        process.execPath,
        resolve(import.meta.dir, "../check-docs-metadata.mjs"),
        site,
      ]);

      expect(command.exitCode).toBe(1);
      expect(command.stderr.toString()).toContain(
        "contains no generated HTML; run `bun run build:docs` first",
      );
    });
  });
});
