// 解析固定的发布说明文件 changes.md，支持按分类分组。
//
// 支持的写法（与历史片段 type 对齐）：
//   ## 新功能         -> feature   新功能
//   ## 问题修复       -> fix       问题修复
//   ## 功能优化       -> optimization 功能优化
//   ## 重要变更       -> breaking  重要变更
//   ## 其他变更       -> other     其他变更
//   （无标题的纯文本行默认归到「其他变更」）
//
// 导出：
//   parseChangesFile(content) -> { sections: [{ type, title, items: string[] }] }
//   renderChangesAsList(content) -> 平铺的 Markdown 列表字符串（无分类时回退）

const CATEGORY_MAP = [
  ["新功能", "feature", "新功能"],
  ["问题修复", "fix", "问题修复"],
  ["功能优化", "optimization", "功能优化"],
  ["重要变更", "breaking", "重要变更"],
  ["其他变更", "other", "其他变更"],
];

const DEFAULT_TYPE = "other";
const DEFAULT_TITLE = "其他变更";

function normalizeItem(line) {
  const trimmed = line.trim().replace(/^[-*]\s*/, "").trim();
  return trimmed;
}

export function parseChangesFile(content) {
  const lines = String(content).replace(/^\uFEFF/, "").split("\n");
  const sections = [];
  let current = null;

  const ensureSection = (type, title) => {
    if (current && current.type === type) return current;
    current = { type, title, items: [] };
    sections.push(current);
    return current;
  };

  for (const raw of lines) {
    const line = raw.trim();
    if (!line) continue;

    const headingMatch = line.match(/^#{1,6}\s*(.+?)\s*$/);
    if (headingMatch) {
      const title = headingMatch[1].trim();
      const matched = CATEGORY_MAP.find(([zh]) => title === zh);
      if (matched) {
        current = ensureSection(matched[1], matched[2]);
        continue;
      }
      // 非分类标题（如 # 发布归档）忽略，不归入内容
      continue;
    }

    const item = normalizeItem(raw);
    if (!item) continue;
    const section = ensureSection(current ? current.type : DEFAULT_TYPE, current ? current.title : DEFAULT_TITLE);
    section.items.push(item);
  }

  return { sections: sections.filter((section) => section.items.length > 0) };
}

export function renderChangesAsList(content) {
  const { sections } = parseChangesFile(content);
  if (sections.length === 0) return "";
  return sections
    .flatMap((section) => section.items.map((item) => `- ${item}`))
    .join("\n");
}

export { CATEGORY_MAP, DEFAULT_TYPE, DEFAULT_TITLE };
