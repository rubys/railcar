#!/usr/bin/env node
// Builds a JSON manifest of files in a generated blog directory.
// Usage: node build-manifest.js <dir> <language>
// Output: { language, files: [{ path, content }] }

const fs = require("fs");
const path = require("path");

const dir = process.argv[2];
const language = process.argv[3];

if (!dir || !language) {
  console.error("Usage: node build-manifest.js <dir> <language>");
  process.exit(1);
}

const SKIP_DIRS = new Set([
  "node_modules", ".git", "lib", "_build", "__pycache__",
  ".pytest_cache", ".mypy_cache", ".venv", "deps", "shard.lock"
]);

const SKIP_EXTENSIONS = new Set([
  ".db", ".sqlite3", ".lock", ".ico", ".png", ".jpg", ".gif",
  ".woff", ".woff2", ".ttf", ".eot", ".map"
]);

function walk(dirPath, prefix) {
  const entries = fs.readdirSync(dirPath, { withFileTypes: true });
  const files = [];

  entries.sort((a, b) => {
    // Directories first, then files, alphabetical within each
    if (a.isDirectory() && !b.isDirectory()) return -1;
    if (!a.isDirectory() && b.isDirectory()) return 1;
    return a.name.localeCompare(b.name);
  });

  for (const entry of entries) {
    const relPath = prefix ? `${prefix}/${entry.name}` : entry.name;

    if (SKIP_DIRS.has(entry.name)) continue;
    if (entry.name.startsWith(".")) continue;

    if (entry.isDirectory()) {
      files.push(...walk(path.join(dirPath, entry.name), relPath));
    } else {
      const ext = path.extname(entry.name);
      if (SKIP_EXTENSIONS.has(ext)) continue;

      try {
        const content = fs.readFileSync(path.join(dirPath, entry.name), "utf-8");
        // Skip binary files
        if (content.includes("\0")) continue;
        files.push({ path: relPath, content });
      } catch {
        // Skip unreadable files
      }
    }
  }

  return files;
}

const files = walk(path.resolve(dir), "");
const manifest = { language, files };
console.log(JSON.stringify(manifest));
