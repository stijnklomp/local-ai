// Repairs agentmemory's strict XML output from local models.
//
// agentmemory's compression and summary parsers reject two things inside text
// fields: a literal `&` (unless it is an entity) and any raw `<`. Local models
// routinely copy shell commands (`&&`) and code comparisons (`a < b`) verbatim.
// The proxy already fixed bare `&`; this module also escapes raw `<` and `>`
// inside the text-only leaf fields, then keeps only the XML root so trailing
// prose or a leading think block does not break parsing.
//
// Structural tags and attributes are never modified.

const BARE_AMP = /&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[\da-fA-F]+);)/g;

// Text-only leaf tags used by the compression, summary and reduce prompts.
const TEXT_LEAF_TAGS =
  "type|title|subtitle|fact|narrative|concept|file|importance|decision";
const TEXT_LEAF = new RegExp(
  `<(${TEXT_LEAF_TAGS})\\b([^>]*)>([\\s\\S]*?)<\\/\\1>`,
  "g",
);
const XML_ROOT = /<(observation|summary)\b[^>]*>[\s\S]*?<\/\1>/;

function escapeText(value) {
  return value.replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

/**
 * Make a model response safe for agentmemory's XML parsers.
 *
 * @param {string} content
 * @returns {string}
 */
export function repairContent(content) {
  if (typeof content !== "string" || content.length === 0) return content;

  // 1. Escape bare ampersands. Existing entities are left alone.
  let out = content.replace(BARE_AMP, "&amp;");

  // 2. Escape character data inside the text-only leaves. The parser rejects
  //    raw `<` and would otherwise treat code snippets as markup.
  out = out.replace(TEXT_LEAF, (match, tag, attrs, inner) => {
    const fixed = escapeText(inner);
    if (fixed === inner) return match;
    return `<${tag}${attrs}>${fixed}</${tag}>`;
  });

  // 3. Drop leading think blocks, prose, code fences and trailing prose; keep
  //    only the first complete <observation> or <summary> element.
  const root = out.match(XML_ROOT);
  return root ? root[0] : out;
}
