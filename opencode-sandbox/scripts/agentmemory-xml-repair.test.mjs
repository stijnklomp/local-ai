import test from "node:test";
import assert from "node:assert/strict";

import { repairContent } from "./agentmemory-xml-repair.mjs";

const TEXT_LEAF =
  /<(type|title|subtitle|fact|narrative|concept|file|importance|decision)\b[^>]*>([\s\S]*?)<\/\1>/g;
const BARE_AMP = /&(?!(?:amp|lt|gt|quot|apos|#\d+|#x[\da-fA-F]+);)/;

// Mirrors the two checks agentmemory's xmlText() applies to a leaf's content.
function assertParserSafe(xml) {
  const leaves = [...xml.matchAll(TEXT_LEAF)];
  assert.ok(leaves.length > 0, "expected at least one text leaf");
  for (const [, tag, inner] of leaves) {
    assert.ok(!inner.includes("<"), `<${tag}> still contains a raw <`);
    assert.ok(!BARE_AMP.test(inner), `<${tag}> still contains a bare &`);
  }
}

test("escapes code comparisons and shell operators in compression output", () => {
  const input = `<observation>
  <type>command_run</type>
  <title>Running grep and npm test</title>
  <facts>
    <fact>Command: grep -n 'if (a < b && c > d)' src/index.ts && npm test</fact>
  </facts>
  <narrative>Found a < b && c > d in src/index.ts.</narrative>
  <concepts><concept>grep search</concept></concepts>
  <files><file>src/index.ts</file></files>
  <importance>6</importance>
</observation>`;

  const out = repairContent(input);

  assertParserSafe(out);
  assert.match(out, /a &lt; b &amp;&amp; c &gt; d/);
  assert.match(out, /<type>command_run<\/type>/);
  assert.match(out, /<importance>6<\/importance>/);
  assert.match(out, /^<observation>/);
  assert.match(out, /<\/observation>$/);
});

test("escapes summary text fields, including nested-looking tags", () => {
  const input = `<summary>
  <title>Parser fix</title>
  <narrative>Handled values where a < b && c > d.</narrative>
  <decisions><decision>Added guards for <undefined> values.</decision></decisions>
  <files><file>src/index.ts</file></files>
  <concepts><concept>parser</concept></concepts>
</summary>`;

  const out = repairContent(input);

  assertParserSafe(out);
  assert.match(out, /&lt;undefined&gt;/);
  assert.match(out, /<decision>/);
});

test("keeps only the root element and drops fences and prose", () => {
  const input = `Sure, here is the result:

\`\`\`xml
<summary>
  <title>Done</title>
  <narrative>All good.</narrative>
</summary>
\`\`\`

Let me know if you need anything else.`;

  const out = repairContent(input);

  assert.equal(
    out,
    `<summary>
  <title>Done</title>
  <narrative>All good.</narrative>
</summary>`,
  );
});

test("strips a leading think block before the root", () => {
  const input = ` thinkingprivate reasoning with a < b</think>
<observation><type>other</type><title>Clean</title></observation>`;

  const out = repairContent(input);

  assert.equal(
    out,
    "<observation><type>other</type><title>Clean</title></observation>",
  );
});

test("does not double-escape existing entities or clean text", () => {
  const input = `<summary>
  <title>Safe &amp; sound</title>
  <narrative>Uses &lt;tag&gt; entities already.</narrative>
</summary>`;

  assert.equal(repairContent(input), input);
});

test("returns non-XML content unchanged", () => {
  assert.equal(repairContent(""), "");
  assert.equal(repairContent("no xml here"), "no xml here");
});
