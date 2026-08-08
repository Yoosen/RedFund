#!/usr/bin/env node

// 发版成功后调用：将固定的 .release-notes/changes.md 内容追加到
// .release-notes/archive.md 顶部（带版本号与日期），随后清空 changes.md，
// 供下一次发版复用。所有内容累积在同一个 archive.md 中，不会无限膨胀成多文件。

import { readFile, writeFile, truncate } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { parseChangesFile } from "./lib/changes-file.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const NOTES_DIR = path.join(root, ".release-notes");
const CHANGES_PATH = path.join(NOTES_DIR, "changes.md");
const ARCHIVE_PATH = path.join(NOTES_DIR, "archive.md");

async function readVersion() {
  if (process.env.RELEASE_PREVIEW_VERSION) return process.env.RELEASE_PREVIEW_VERSION;
  const raw = await readFile(path.join(root, "package.json"), "utf8");
  return JSON.parse(raw).version;
}

const version = await readVersion();
const date = (process.env.RELEASE_PREVIEW_DATE || new Date().toISOString().slice(0, 10));

let changes;
try {
  changes = (await readFile(CHANGES_PATH, "utf8")).trim();
} catch (error) {
  if (error?.code === "ENOENT") changes = "";
  else throw error;
}

if (!changes) {
  process.stdout.write("changes.md 为空，跳过归档。\n");
  process.exit(0);
}

// 解析分类结构；没有 ## 分类标题时，所有内容归到「其他变更」。
const { sections } = parseChangesFile(changes);
const block = sections.length > 0
  ? `## v${version} - ${date}\n\n${sections
    .map((section) => `### ${section.title}\n\n${section.items.map((item) => `- ${item}`).join("\n")}`)
    .join("\n\n")}\n`
  : `## v${version} - ${date}\n\n- 本次发布仅重新打包，不包含功能变更。\n`;

let existing = "";
try {
  existing = (await readFile(ARCHIVE_PATH, "utf8")).replace(/^\uFEFF/, "");
} catch (error) {
  if (error?.code !== "ENOENT") throw error;
}

// 已有的 archive 顶部可能带一级标题 + 引导说明，保留它们，再在其后插入新块。
const leadMatch = existing.match(/^# .*(?:\n[^\n#].*)*\n+/);
let lead = "";
let body = existing;
if (leadMatch) {
  lead = leadMatch[0];
  body = existing.slice(lead.length);
} else if (existing.startsWith("# ")) {
  const nl = existing.indexOf("\n");
  lead = existing.slice(0, nl + 1);
  body = existing.slice(nl + 1);
}

const updated = `${lead.replace(/\s+$/, "")}\n\n${block.trim()}\n\n${body.replace(/^\n+/, "").replace(/\s+$/, "")}\n`;

await writeFile(ARCHIVE_PATH, updated);
await truncate(CHANGES_PATH, 0);

process.stdout.write(`已归档 v${version} 到 archive.md，并清空 changes.md。\n`);
