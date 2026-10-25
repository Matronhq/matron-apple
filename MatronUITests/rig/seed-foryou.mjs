// For you rig: a long For you list on the demo journal, for measuring how
// smoothly it scrolls. Files 80 items that need the user (questions with
// buttons, notices, and tasks handed to the user) with bodies of a few
// paragraphs, and 240 closed ones for the Done tab, across the demo
// conversations.
//
// Every third body is a long report of about 10 KB.
//
// Run after seed.mjs: cd /tmp/matron-demo && node seed-foryou.mjs
import fs from 'node:fs';

const BASE = 'http://127.0.0.1:9810';
const macToken = fs.readFileSync('/tmp/matron-demo/agent-mac-studio.txt', 'utf8').split('token:')[1].trim().split(/\s/)[0];
const CONVOS = ['demo-fix-flaky-upload', 'demo-auth-refactor', 'demo-dark-mode', 'demo-release-notes',
  'demo-memory-spike'];

async function call(path, body) {
  const res = await fetch(BASE + path, {
    method: 'POST',
    headers: { authorization: `Bearer ${macToken}`, 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${path}: ${res.status} ${text}`);
  return JSON.parse(text);
}

const topics = ['the upload retry queue', 'the sign-in token refresh', 'dark mode contrast', 'the 2.4 release notes',
  'the memory spike on launch', 'the nightly homelab backup', 'the search index rebuild', 'push notification grouping',
  'the settings window width', 'the voice mode queue'];

function body(i) {
  const topic = topics[i % topics.length];
  const paragraphs = [
    `I looked into **${topic}** this morning. The short version: it fails about one run in ${3 + (i % 7)}, and only when the link drops for longer than the retry delay.`,
    `- Option A keeps the current design and adds a longer timeout.\n- Option B replaces it with a manifest and resumable chunks.\n- Option C does nothing for now and logs the failures.`,
    `| Option | Effort | Risk |\n| :--- | :--- | :--- |\n| A | 1 day | Hides the failure |\n| B | 4 days | New endpoint |\n| C | none | Users still see it |`,
    `My recommendation is option B. It is the only one that removes the failure rather than hiding it. See [the run log](https://example.com/runs/${i}) for the numbers.`,
  ];
  const short = paragraphs.slice(0, 2 + (i % 3)).join('\n\n');
  // Every third item is a long report, as agents often file: about 10 KB.
  if (i % 3 !== 0) return short;
  const sections = [];
  for (let n = 1; sections.join('').length < 10000; n++) {
    sections.push(`## Finding ${n}\n\n${short}\n\n\`\`\`\nrun ${n}: ${'ok '.repeat(20)}\n\`\`\``);
  }
  return sections.join('\n\n');
}

for (let i = 0; i < 80; i++) {
  const kind = i % 5 === 0 ? 'notice' : i % 7 === 0 ? 'task' : 'question';
  const fields = {
    kind, convo_id: CONVOS[i % CONVOS.length],
    title: `${kind === 'notice' ? 'Heads up on' : kind === 'task' ? 'Check' : 'Decide on'} ${topics[i % topics.length]} (${i + 1})`,
    body: body(i),
  };
  if (kind === 'question') fields.actions = ['Option A', 'Option B', 'Option C'];
  if (kind === 'task') fields.awaiting = 'user';
  await call('/items', fields);
}
for (let i = 0; i < 240; i++) {
  const kind = i % 3 === 0 ? 'decision' : 'question';
  const { item } = await call('/items', {
    kind, convo_id: CONVOS[i % CONVOS.length],
    title: `Settled: ${topics[i % topics.length]} (${i + 1})`, body: body(i),
  });
  await call(`/items/${item.id}/close`, { resolution: kind === 'decision' ? 'decided' : 'answered' });
}
console.log('seeded For you: 80 open, 240 closed');
