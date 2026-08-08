#!/usr/bin/env node

// 生成「本次发布更新说明」预览（仅展示，不写入仓库、不消费 release 片段）。
// 用于 CI（tag-release.yml）在打 tag 时把面向用户的改动汇总成一份说明文字，
// 作为 artifact 供开发者下载参考。仓库的 CHANGELOG.md 与 .release-notes 片段
// 仍由本地 scripts/release.sh 在正式发布时处理。

import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { buildChangelogEntry, loadReleaseNoteFragments } from "./lib/release-notes.mjs";
import { parseChangesFile } from "./lib/changes-file.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");

async function readVersion() {
  if (process.env.RELEASE_PREVIEW_VERSION) return process.env.RELEASE_PREVIEW_VERSION;
  const raw = await readFile(path.join(root, "package.json"), "utf8");
  return JSON.parse(raw).version;
}

async function readChangesFile() {
  const changesPath = path.join(root, ".release-notes", "changes.md");
  try {
    const content = await readFile(changesPath, "utf8");
    const trimmed = content.trim();
    return trimmed.length > 0 ? trimmed : null;
  } catch (error) {
    if (error?.code === "ENOENT") return null;
    throw error;
  }
}

// 读取上一个 tag（用于生成版本间代码差异对比链接）。
// 优先取环境变量（CI 传入），否则回退用 git 定位 HEAD^ 的最近 tag。
async function readPreviousTag() {
  if (process.env.RELEASE_PREVIEW_PREVIOUS_TAG) return process.env.RELEASE_PREVIEW_PREVIOUS_TAG;
  try {
    const { execFileSync } = await import("node:child_process");
    return execFileSync("git", ["describe", "--tags", "--abbrev=0", "HEAD^"], {
      cwd: root,
      encoding: "utf8",
    }).trim() || "";
  } catch {
    return "";
  }
}

// 把解析出的分类 sections 渲染成按「标题」分组的 Markdown 块。
function renderClassifiedSections(sections) {
  return sections
    .map((section) => `### ${section.title}\n\n${section.items.map((item) => `- ${item}`).join("\n")}`)
    .join("\n\n");
}

async function main() {
  const version = await readVersion();
  const date = (process.env.RELEASE_PREVIEW_DATE || new Date().toISOString().slice(0, 10));
  const fragmentsDir = path.join(root, ".release-notes");

  const manualNotes = await readChangesFile();
  const { sections } = manualNotes ? parseChangesFile(manualNotes) : { sections: [] };

  let entry;
  if (sections.length > 0) {
    // 固定单文件 changes.md（支持 ## 分类）优先。
    const content = renderClassifiedSections(sections);
    entry = `## v${version} - ${date}\n\n${content.trim()}\n`;
  } else {
    // 回退：旧的片段机制（仅当 changes.md 为空时）。
    const { fragments } = await loadReleaseNoteFragments(fragmentsDir);
    entry = buildChangelogEntry({
      version,
      date,
      fragments,
      allowEmpty: true,
    });
  }

  // 追加「上一个版本 → 当前版本」的代码差异对比链接（与原作者 releases 一致）。
  const previousTag = await readPreviousTag();
  if (previousTag) {
    const tag = `v${version}`;
    const url = `https://github.com/Yoosen/RedFund/compare/${encodeURIComponent(previousTag)}...${encodeURIComponent(tag)}`;
    entry = `${entry.trimEnd()}\n\n## 代码变更\n\n[查看 ${previousTag} → ${tag} 的完整代码差异](${url})\n`;
  }

  // 同时写文件（供 artifact 上传）并打印到日志。
  // 放在 .release-notes/ 下，避免污染仓库根目录。
  const outPath = path.join(root, ".release-notes", "RELEASE_NOTES_PREVIEW.md");
  await (await import("node:fs/promises")).writeFile(outPath, entry);
  process.stdout.write(`\n${entry}\n`);
  process.stdout.write(`Release notes preview written to ${outPath}\n`);
}

main().catch((error) => {
  process.stderr.write(`generate-release-notes-preview: ${error.message}\n`);
  process.exitCode = 1;
});
