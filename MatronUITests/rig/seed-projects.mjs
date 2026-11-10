// Projects rig: a made-up user's projects, for walking the Projects
// screens (the week page, All projects, a project page with its history,
// missions and files) in the real apps. It files about a dozen projects
// with missions, milestones over the last six weeks, items (some waiting
// on the user, some closed this week) and pictures drawn here; then, as
// the user's Coordinator, it writes this week and last week one entry per
// project.
//
// The journal stamps every row with the time of the write, so the script
// ends by moving the rows back in time in the demo database (as
// rebuild-rig.sh back-dates the demo chats). It therefore needs the
// `sqlite3` command and must run on the machine that holds the database.
//
// Run against a fresh demo journal (see README.md, "Projects rig"):
//   RIG_DIR=/tmp/matron-projects-demo RIG_PORT=9847 node seed-projects.mjs
// RIG_DIR holds matron.db, agent-mac-studio.txt and login-client.json, as
// rebuild-rig.sh writes them; the defaults are the rig's own
// (/tmp/matron-demo, 9810). Needs Node 22 (its built-in WebSocket), so no
// node_modules. The short video is made with ffmpeg when it is installed;
// without it a placeholder file takes its place.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';
import { execFileSync } from 'node:child_process';

const DIR = process.env.RIG_DIR ?? '/tmp/matron-demo';
const PORT = process.env.RIG_PORT ?? '9810';
const BASE = `http://127.0.0.1:${PORT}`;
const DB = path.join(DIR, 'matron.db');
const agentToken = fs.readFileSync(path.join(DIR, 'agent-mac-studio.txt'), 'utf8').split('token:')[1].trim().split(/\s/)[0];
const client = JSON.parse(fs.readFileSync(path.join(DIR, 'login-client.json'), 'utf8'));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function call(token, method, route, body, headers = {}) {
  const raw = typeof body === 'string' || body instanceof Uint8Array;
  const res = await fetch(BASE + route, {
    method,
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json', ...headers },
    body: body === undefined ? undefined : raw ? body : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${route}: ${res.status} ${text}`);
  return JSON.parse(text);
}
const post = (route, body, headers) => call(agentToken, 'POST', route, body, headers);

// ---- Time. Weeks are the user's: Monday 00:00 in Europe/London. ----
const NOW = Date.now();
const DAY = 86_400_000;
const london = (ms) => {
  const parts = Object.fromEntries(new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/London', weekday: 'short', year: 'numeric', month: '2-digit', day: '2-digit',
  }).formatToParts(ms).map((p) => [p.type, p.value]));
  return { key: `${parts.year}-${parts.month}-${parts.day}`, weekday: ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].indexOf(parts.weekday) };
};
// Noon UTC on this week's Monday: the same calendar day in London all year.
const today = london(NOW);
const mondayNoon = Date.parse(`${today.key}T12:00:00Z`) - today.weekday * DAY;
const weekKey = (weeksAgo) => new Date(mondayNoon - weeksAgo * 7 * DAY).toISOString().slice(0, 10);
// A moment `weeksAgo` weeks back, on `day` (0 = Monday) at `hour` UTC. A
// moment still to come this week is pulled back to a little before now.
let pulled = 0;
function at(weeksAgo, day, hour) {
  const t = mondayNoon - weeksAgo * 7 * DAY + day * DAY + (hour - 12) * 3_600_000;
  return t < NOW - 120_000 ? t : NOW - 120_000 - (40 - Math.min(40, pulled++)) * 60_000;
}

// ---- Pictures, drawn here so the rig carries no picture files. ----
function canvas(width, height, background) {
  const rows = Buffer.alloc((width * 3 + 1) * height);
  const c = {
    width, height,
    rect(x, y, w, h, [r, g, b]) {
      for (let yy = Math.max(0, y); yy < Math.min(height, y + h); yy++) {
        const row = yy * (width * 3 + 1) + 1;
        for (let xx = Math.max(0, x); xx < Math.min(width, x + w); xx++) {
          rows[row + xx * 3] = r; rows[row + xx * 3 + 1] = g; rows[row + xx * 3 + 2] = b;
        }
      }
      return c;
    },
    // Grey bars standing in for lines of text.
    lines(x, y, w, count, colour = [205, 210, 218], gap = 26, height_ = 10) {
      for (let i = 0; i < count; i++) c.rect(x, y + i * gap, i === count - 1 ? Math.round(w * 0.6) : w, height_, colour);
      return c;
    },
    png() {
      const crcTable = Array.from({ length: 256 }, (_, n) => {
        let v = n;
        for (let k = 0; k < 8; k++) v = v & 1 ? 0xedb88320 ^ (v >>> 1) : v >>> 1;
        return v >>> 0;
      });
      const crc = (buf) => {
        let v = 0xffffffff;
        for (const byte of buf) v = crcTable[(v ^ byte) & 0xff] ^ (v >>> 8);
        return (v ^ 0xffffffff) >>> 0;
      };
      const chunk = (type, data) => {
        const head = Buffer.alloc(4); head.writeUInt32BE(data.length);
        const body = Buffer.concat([Buffer.from(type), data]);
        const tail = Buffer.alloc(4); tail.writeUInt32BE(crc(body));
        return Buffer.concat([head, body, tail]);
      };
      const header = Buffer.alloc(13);
      header.writeUInt32BE(width, 0); header.writeUInt32BE(height, 4);
      header[8] = 8; header[9] = 2;
      return Buffer.concat([
        Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
        chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(rows)), chunk('IEND', Buffer.alloc(0)),
      ]);
    },
  };
  return c.rect(0, 0, width, height, background);
}

const WHITE = [255, 255, 255];
const PAPER = [244, 246, 249];
const INK = [38, 44, 56];

// A desktop page: a bar in the project's colour, a sidebar and cards.
function page(colour, { dark = false } = {}) {
  const back = dark ? [24, 27, 33] : PAPER;
  const card = dark ? [40, 44, 53] : WHITE;
  const text = dark ? [92, 99, 112] : [205, 210, 218];
  const c = canvas(1600, 1000, back).rect(0, 0, 1600, 84, colour).rect(40, 30, 220, 24, WHITE)
    .rect(0, 84, 300, 916, card);
  for (let i = 0; i < 7; i++) c.rect(36, 130 + i * 58, 150 + (i % 3) * 30, 14, i === 1 ? colour : text);
  for (let i = 0; i < 4; i++) {
    const x = 350 + (i % 2) * 610, y = 134 + Math.floor(i / 2) * 420;
    c.rect(x, y, 570, 380, card).rect(x + 30, y + 30, 510, 170, i === 0 ? colour : text)
      .rect(x + 30, y + 228, 300, 18, dark ? [200, 205, 214] : INK).lines(x + 30, y + 270, 510, 3, text);
  }
  return c.png();
}

// A phone screen, about 600 x 1300: a search field and a list of results.
function phone(colour) {
  const c = canvas(600, 1300, WHITE).rect(0, 0, 600, 150, colour).rect(36, 84, 528, 46, WHITE)
    .rect(56, 100, 200, 14, [170, 176, 186]);
  for (let i = 0; i < 9; i++) {
    const y = 190 + i * 118;
    c.rect(36, y, 72, 72, i % 3 === 0 ? colour : [226, 230, 236]).rect(132, y + 8, 260 + (i % 4) * 40, 16, INK)
      .lines(132, y + 40, 400, 2, [205, 210, 218], 20, 8).rect(36, y + 96, 528, 2, [236, 238, 242]);
  }
  return c.rect(0, 1216, 600, 84, PAPER).rect(230, 1270, 140, 8, INK).png();
}

// A very wide strip, about 2000 x 300: a navigation bar with its tabs.
function strip(colour) {
  const c = canvas(2000, 300, WHITE).rect(0, 0, 2000, 8, colour).rect(60, 110, 80, 80, colour)
    .rect(170, 136, 240, 28, INK);
  for (let i = 0; i < 6; i++) c.rect(560 + i * 190, 140, 130, 20, i === 2 ? colour : [150, 157, 168]);
  return c.rect(560 + 2 * 190, 176, 130, 6, colour).rect(1720, 118, 220, 64, colour).rect(1760, 142, 140, 16, WHITE).png();
}

// A row of swatches: the same small screen in several themes.
function swatches() {
  const themes = [[[250, 250, 252], [60, 110, 220]], [[28, 30, 36], [120, 160, 255]], [[247, 240, 226], [150, 96, 40]],
    [[18, 34, 40], [70, 190, 170]]];
  const c = canvas(1600, 1000, PAPER);
  themes.forEach(([back, accent], i) => {
    const x = 70 + i * 380;
    const text = back[0] > 128 ? [190, 190, 196] : [86, 92, 104];
    c.rect(x, 110, 320, 780, back).rect(x, 110, 320, 70, accent).rect(x + 30, 220, 180, 18, text)
      .lines(x + 30, 270, 260, 4, text).rect(x + 30, 420, 260, 150, accent).lines(x + 30, 610, 260, 5, text)
      .rect(x + 30, 800, 120, 44, accent);
  });
  return c.png();
}

// A bar chart: start-up time, release by release.
function chart(colour) {
  const c = canvas(1600, 1000, WHITE).rect(120, 100, 4, 760, INK).rect(120, 860, 1360, 4, INK);
  [620, 600, 560, 430, 390, 250, 230].forEach((h, i) => {
    c.rect(200 + i * 180, 860 - h, 110, h, i >= 5 ? colour : [196, 202, 212]).rect(205 + i * 180, 890, 100, 12, [150, 157, 168]);
  });
  return c.rect(120, 420, 1360, 2, [230, 120, 100]).png();
}

// Two seconds of video. Without ffmpeg (or if it fails) the file is a
// placeholder the apps can list but not play.
function clip() {
  const out = path.join(os.tmpdir(), `seed-projects-${process.pid}.mp4`);
  for (const codec of ['libx264', 'h264_videotoolbox']) {
    try {
      execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-f', 'lavfi', '-i',
        'gradients=s=1280x720:d=2:c0=0x1d3557:c1=0xe76f51:speed=0.05', '-r', '30', '-c:v', codec,
        '-pix_fmt', 'yuv420p', '-movflags', '+faststart', out], { stdio: 'ignore' });
      const bytes = fs.readFileSync(out);
      fs.rmSync(out, { force: true });
      return bytes;
    } catch { fs.rmSync(out, { force: true }); }
  }
  console.warn('seed-projects: no ffmpeg, using a placeholder for the video');
  return Buffer.concat([Buffer.from([0, 0, 0, 24]), Buffer.from('ftypmp42'), Buffer.alloc(4), Buffer.from('mp42isom'),
    Buffer.from([0, 0, 0, 8]), Buffer.from('free')]);
}

const BLUE = [52, 110, 222], CORAL = [226, 104, 82], GREEN = [46, 156, 122], VIOLET = [124, 92, 214],
  AMBER = [222, 160, 44], TEAL = [38, 150, 170], ROSE = [206, 80, 130], SLATE = [86, 100, 126];

const uploads = new Map();
async function upload(name, mime, bytes) {
  const blob = await post('/media', bytes, { 'content-type': mime });
  const file = { blob_ref: blob.media_id, mime, name, size: bytes.length };
  uploads.set(name, file);
  return file;
}
const FILES = {
  'navigation-bar.png': () => strip(BLUE),
  'guides-home.png': () => page(BLUE),
  'launch-page.png': () => page(CORAL),
  'launch-page-dark.png': () => page(CORAL, { dark: true }),
  'promo-clip.mp4': () => clip(),
  'search-on-iphone.png': () => phone(GREEN),
  'search-results-tablet.png': () => page(GREEN),
  'theme-swatches.png': () => swatches(),
  'sepia-reading.png': () => page([150, 96, 40]),
  'offline-banner.png': () => strip(AMBER),
  'offline-chat.png': () => phone(AMBER),
  'statement-layout.png': () => page(TEAL),
  'contrast-before-after.png': () => page(ROSE, { dark: true }),
  'tour-first-screen.png': () => phone(VIOLET),
  'start-up-time.png': () => chart(SLATE),
  'tablet-two-columns.png': () => page(SLATE),
  'icon-options.png': () => swatches(),
};
const fileNamed = async (name) => uploads.get(name)
  ?? upload(name, name.endsWith('.mp4') ? 'video/mp4' : 'image/png', FILES[name]());

// ---- The projects. Times are at(weeksAgo, day, hour). ----
// A milestone is [when, title]. An item is { kind, title, body?, when,
// waiting?, actions?, closed?, comments: [[when, body, file names?]] }.
const PROJECTS = [
  {
    title: 'Docs site launch',
    status: 'The guides are on the new site and search works. The launch checklist has two things left: redirects from the old addresses and a last read of the getting-started guide.',
    missions: [
      { title: 'Move the guides to the new site', started: at(6, 1, 9), closed: at(3, 3, 16),
        summary: 'All 42 guides are on the new site with their pictures.',
        milestones: [[at(6, 1, 10), 'Listed every guide and where it lives today'], [at(5, 2, 14), 'First twenty guides moved, pictures included'],
          [at(4, 1, 11), 'The rest of the guides moved'], [at(3, 3, 15), 'Every guide checked against the old site']],
        items: [{ kind: 'decision', title: 'Keep the old page addresses and redirect them', when: at(5, 3, 10), closed: at(5, 3, 11),
          comments: [[at(5, 3, 10), 'Nobody has to update a bookmark, and search engines keep what they know.']] }] },
      { title: 'Search and navigation', started: at(4, 2, 9), state: 'running',
        status: 'Search is live on the new site. The navigation bar is waiting on a choice of tab order.',
        milestones: [[at(4, 2, 12), 'Search box finds guides by title'], [at(3, 1, 15), 'Search reads the whole guide, not only the title'],
          [at(2, 2, 11), 'New navigation bar drawn'], [at(1, 1, 14), 'Navigation bar built and on the test site'],
          [at(0, 0, 11), 'Search results show the matching sentence']],
        items: [{ kind: 'question', title: 'Which order for the tabs in the navigation bar?', when: at(1, 1, 15), waiting: true,
          actions: ['Guides first', 'Reference first'],
          body: 'The bar is built. Guides, Reference, Examples and Help can go in either order; most visitors open a guide first.',
          comments: [[at(1, 1, 15), 'Here is the bar with Guides first.', ['navigation-bar.png']],
            [at(0, 0, 12), 'And the guides home page it leads to.', ['guides-home.png']]] }] },
      { title: 'Launch checklist', started: at(1, 0, 9), state: 'waiting',
        milestones: [[at(1, 0, 10), 'Wrote the checklist for launch day'], [at(1, 3, 16), 'Old addresses mapped to new ones'],
          [at(0, 1, 9), 'Redirects tested on the test site']],
        items: [{ kind: 'task', title: 'Read the getting-started guide once more before launch', when: at(0, 0, 10), waiting: true,
          body: 'It is the page most new visitors land on. Ten minutes, start to finish.', comments: [] },
        { kind: 'task', title: 'Check every redirect from the old site', when: at(1, 3, 16), closed: at(0, 1, 9),
          comments: [[at(0, 1, 9), 'All 42 old addresses land on the right guide.']] }] },
    ],
  },
  {
    title: 'Promo launch',
    status: 'The launch page is ready in light and dark. The video is cut to 40 seconds and needs your yes on the ending.',
    missions: [
      { title: 'Launch-day page', started: at(3, 0, 10), state: 'waiting',
        milestones: [[at(3, 0, 11), 'Outline of the page agreed'], [at(2, 1, 15), 'First full draft of the page'],
          [at(1, 2, 12), 'Page built, light and dark'], [at(0, 0, 15), 'Page loads in under a second on a phone']],
        items: [{ kind: 'notice', title: 'The launch page is ready to look at', when: at(1, 2, 13), closed: at(0, 0, 15), resolution: 'done',
          comments: [[at(1, 2, 13), 'Light version.', ['launch-page.png']], [at(1, 2, 14), 'Dark version.', ['launch-page-dark.png']]] }] },
      { title: 'Promo video', started: at(2, 2, 9), state: 'waiting',
        status: 'Cut to 40 seconds. Two endings to choose from.',
        milestones: [[at(2, 2, 10), 'Script for a 40-second video'], [at(1, 3, 11), 'Screen recordings done'],
          [at(0, 1, 10), 'First cut of the video']],
        items: [{ kind: 'question', title: 'Which ending for the promo video?', when: at(0, 1, 10), waiting: true,
          actions: ['End on the app', 'End on the logo'],
          body: 'Both run 40 seconds. Ending on the app shows one more feature; ending on the logo is calmer.',
          comments: [[at(0, 1, 10), 'The first cut, ending on the app.', ['promo-clip.mp4']]] }] },
      { title: 'Email announcement', started: at(2, 3, 9), closed: at(1, 4, 15),
        summary: 'The announcement is written and scheduled for launch morning.',
        milestones: [[at(2, 3, 14), 'Draft of the announcement'], [at(1, 4, 14), 'Announcement scheduled for launch morning']],
        items: [] },
    ],
  },
  {
    title: 'Search in the mobile apps',
    status: 'Search works on iPhone and finds messages as you type. The tablet layout is next.',
    missions: [
      { title: 'Search index on the server', started: at(6, 0, 9), closed: at(4, 3, 16),
        summary: 'Every message is indexed and a search answers in under a tenth of a second.',
        milestones: [[at(6, 0, 12), 'Chose how to index messages'], [at(5, 1, 10), 'Index built for new messages'],
          [at(4, 3, 15), 'Old messages indexed too']],
        items: [] },
      { title: 'Search on iPhone', started: at(3, 1, 9), state: 'running',
        milestones: [[at(3, 1, 11), 'Search field in the chat list'], [at(2, 3, 15), 'Results as you type'],
          [at(1, 1, 10), 'Tapping a result opens the chat at that message'], [at(0, 0, 14), 'Recent searches remembered'],
          [at(0, 1, 11), 'Search works without a connection for chats already on the phone']],
        items: [{ kind: 'notice', title: 'Search on iPhone, as it looks today', when: at(0, 0, 14), waiting: true,
          comments: [[at(0, 0, 14), 'The search screen with results.', ['search-on-iphone.png']]] },
        { kind: 'task', title: 'Highlight the matching words in a result', when: at(1, 2, 9), closed: at(0, 0, 16),
          comments: [[at(0, 0, 16), 'Done: the words you typed are bold in each result.']] }] },
      { title: 'Search on tablets', started: at(1, 3, 9), state: 'done',
        milestones: [[at(1, 3, 12), 'Sketched results beside the chat']],
        items: [{ kind: 'question', title: 'On a tablet, show results beside the chat or over it?', when: at(1, 3, 13), waiting: true,
          actions: ['Beside the chat', 'Over the chat'], body: 'Beside keeps the chat in view; over gives results the whole width.',
          comments: [[at(1, 3, 13), 'A sketch of results beside the chat.', ['search-results-tablet.png']]] }] },
    ],
  },
  {
    title: 'Themes',
    status: 'Four themes are built. The picker shows them side by side.',
    missions: [
      { title: 'Dark and sepia themes', started: at(4, 0, 10), state: 'done',
        milestones: [[at(4, 0, 11), 'Colours named so a theme can swap them'], [at(3, 2, 14), 'Dark theme on every screen'],
          [at(1, 0, 15), 'Sepia theme for reading'], [at(0, 0, 9), 'A fourth theme, deep green']],
        items: [{ kind: 'notice', title: 'The four themes side by side', when: at(0, 0, 9), closed: at(0, 1, 8), resolution: 'done',
          comments: [[at(0, 0, 9), 'Light, dark, sepia and deep green.', ['theme-swatches.png']],
            [at(1, 0, 16), 'Sepia on a long guide.', ['sepia-reading.png']]] }] },
      { title: 'Theme picker', started: at(1, 2, 9), state: 'running',
        milestones: [[at(1, 2, 11), 'Picker in Settings'], [at(0, 1, 12), 'The picker previews a theme before you choose it']],
        items: [] },
    ],
  },
  {
    title: 'Offline mode',
    status: 'Chats open without a connection and messages wait in a queue. What happens when two devices edit the same draft is still open.',
    missions: [
      { title: 'Read chats offline', started: at(5, 0, 9), closed: at(2, 4, 15),
        summary: 'Every chat opened in the last month can be read without a connection.',
        milestones: [[at(5, 0, 11), 'Chats kept on the device'], [at(4, 1, 15), 'Pictures kept too, up to a size limit'],
          [at(2, 4, 14), 'A banner says when you are offline']],
        items: [{ kind: 'notice', title: 'The offline banner', when: at(2, 4, 14), closed: at(2, 4, 16), resolution: 'done',
          comments: [[at(2, 4, 14), 'The banner across the top of the app.', ['offline-banner.png']]] }] },
      { title: 'Queue messages while offline', started: at(2, 0, 9), state: 'running',
        milestones: [[at(2, 0, 12), 'Messages written offline wait in a queue'], [at(1, 1, 16), 'The queue sends in order when the connection returns'],
          [at(0, 0, 13), 'A waiting message can be edited or removed']],
        items: [{ kind: 'notice', title: 'A chat with two messages waiting to send', when: at(0, 0, 13), closed: at(0, 1, 9), resolution: 'done',
          comments: [[at(0, 0, 13), 'Waiting messages are marked with a clock.', ['offline-chat.png']]] }] },
      { title: 'Sync conflicts', started: at(1, 4, 9), state: 'waiting',
        milestones: [[at(1, 4, 11), 'Listed the ways two devices can disagree']],
        items: [{ kind: 'question', title: 'Two devices edited the same draft: which one wins?', when: at(1, 4, 12), waiting: true,
          actions: ['The newer edit', 'Keep both'], body: 'Keeping both never loses words but leaves the user to tidy up.', comments: [] }] },
    ],
  },
  {
    title: 'Billing export',
    status: 'The spreadsheet export is done. The monthly statement has a layout and needs real numbers checked against it.',
    missions: [
      { title: 'Spreadsheet export', started: at(4, 3, 9), closed: at(1, 2, 16),
        summary: 'Any date range exports as a spreadsheet, one row per invoice.',
        milestones: [[at(4, 3, 12), 'Agreed the columns'], [at(3, 3, 11), 'Export for one month'], [at(1, 2, 15), 'Export for any date range']],
        items: [{ kind: 'decision', title: 'One row per invoice, not per line', when: at(4, 3, 13), closed: at(4, 3, 14),
          comments: [[at(4, 3, 13), 'It is what an accountant expects to import.']] }] },
      { title: 'Monthly statement', started: at(1, 0, 9), state: 'done',
        milestones: [[at(1, 0, 14), 'Layout of the statement drawn'], [at(0, 0, 10), 'Statement builds as a file you can print']],
        items: [{ kind: 'task', title: 'Check one month of the statement against the invoices', when: at(0, 0, 11), waiting: true,
          body: 'Pick any month; the totals at the bottom should match.',
          comments: [[at(0, 0, 11), 'The layout.', ['statement-layout.png']]] }] },
    ],
  },
  {
    title: 'Accessibility audit',
    status: 'Contrast is fixed everywhere. The screen-reader pass found 14 things; nine are done.',
    missions: [
      { title: 'Contrast fixes', started: at(5, 2, 9), closed: at(2, 1, 15),
        summary: 'Every text and button passes the contrast check in all themes.',
        milestones: [[at(5, 2, 12), 'Measured contrast on every screen'], [at(3, 0, 15), 'Grey text darkened'], [at(2, 1, 14), 'Buttons pass in dark mode too']],
        items: [{ kind: 'notice', title: 'Contrast before and after', when: at(2, 1, 14), closed: at(2, 1, 16), resolution: 'done',
          comments: [[at(2, 1, 14), 'The settings screen in dark mode.', ['contrast-before-after.png']]] }] },
      { title: 'Screen reader pass', started: at(2, 2, 9), state: 'running',
        milestones: [[at(2, 2, 14), 'Went through every screen with the screen reader on'], [at(1, 2, 10), 'Buttons without names now have them'],
          [at(0, 1, 13), 'The chat list reads sender, time and message in that order']],
        items: [{ kind: 'task', title: 'Name the picture buttons in the composer', when: at(1, 2, 11), closed: at(0, 1, 13),
          comments: [[at(0, 1, 13), 'Each one now says what it does.']] }] },
      { title: 'Keyboard navigation', started: at(1, 1, 9), state: 'done',
        milestones: [[at(1, 1, 12), 'Every screen reachable with the Tab key']], items: [] },
    ],
  },
  {
    title: 'Onboarding tour',
    status: 'Three screens that show a new user where things are. The words are written; the pictures are placeholders.',
    missions: [
      { title: 'A three-screen tour for new users', started: at(2, 1, 9), state: 'done',
        milestones: [[at(2, 1, 13), 'Chose the three things a new user must know'], [at(1, 3, 10), 'Words for each screen'],
          [at(0, 0, 12), 'Tour runs on first launch and can be skipped']],
        items: [{ kind: 'notice', title: 'First screen of the tour', when: at(0, 0, 12), closed: at(0, 0, 17), resolution: 'done',
          comments: [[at(0, 0, 12), 'The first of three.', ['tour-first-screen.png']]] }] },
    ],
  },
  {
    title: 'Faster app start',
    missions: [
      { title: 'Measure start-up', started: at(3, 1, 9), closed: at(2, 0, 12),
        summary: 'Start-up is measured on every build and charted.',
        milestones: [[at(3, 1, 14), 'Start-up time measured on every build'], [at(2, 0, 11), 'Chart of start-up time, release by release']],
        items: [] },
      { title: 'Load the chat list first', started: at(2, 0, 13), state: 'running',
        milestones: [[at(1, 0, 16), 'Chat list shows before anything else loads'], [at(0, 1, 8), 'Start-up down from two seconds to under one']],
        items: [{ kind: 'notice', title: 'Start-up time, last seven releases', when: at(0, 1, 8), waiting: true,
          comments: [[at(0, 1, 8), 'The last two bars are this work.', ['start-up-time.png']]] }] },
    ],
  },
  {
    title: 'Notification settings',
    status: 'Each chat can be muted for an hour, a day or for good.',
    missions: [
      { title: 'Mute a chat for a while', started: at(3, 3, 9), state: 'done',
        milestones: [[at(3, 3, 12), 'Mute for an hour or a day'], [at(1, 1, 11), 'A muted chat shows a small bell with a line through it'],
          [at(1, 4, 10), 'Muting carries over to your other devices']],
        items: [{ kind: 'question', title: 'Should a muted chat still show its unread count?', when: at(1, 4, 11), waiting: true,
          actions: ['Yes, in grey', 'No'], comments: [] }] },
    ],
  },
  // Went quiet: busy for three weeks, then nothing for three.
  {
    title: 'Tablet layout',
    status: 'Two columns work in landscape. Portrait is not started.',
    missions: [
      { title: 'Two columns on a tablet', started: at(5, 0, 10), state: 'done',
        milestones: [[at(5, 0, 14), 'Chat list and chat side by side in landscape'], [at(4, 2, 11), 'The divider can be dragged'],
          [at(3, 1, 15), 'The layout survives turning the tablet']],
        items: [{ kind: 'notice', title: 'Two columns in landscape', when: at(3, 1, 15), closed: at(3, 1, 16), resolution: 'done',
          comments: [[at(3, 1, 15), 'List on the left, chat on the right.', ['tablet-two-columns.png']]] }] },
    ],
  },
  // Finished: one closed as a project, one whose last mission closed.
  {
    title: 'Password reset by email', closed: at(2, 3, 12), summary: 'Anyone with an email address on file can reset their own password.',
    status: 'Shipped. A reset link arrives by email and works once.',
    missions: [
      { title: 'Reset link by email', started: at(6, 2, 9), closed: at(3, 2, 15), summary: 'Reset links are sent, expire after half an hour and work once.',
        milestones: [[at(6, 2, 12), 'Reset link sent by email'], [at(4, 4, 10), 'A link works once and expires'], [at(3, 2, 14), 'Released']],
        items: [] },
      { title: 'Forgot password on the sign-in screen', started: at(4, 0, 9), closed: at(2, 3, 11), summary: 'Every sign-in screen has the link.',
        milestones: [[at(4, 0, 15), 'Link on the sign-in screen'], [at(2, 3, 10), 'Released in every app']], items: [] },
    ],
  },
  {
    title: 'New app icon',
    status: 'The new icon is in every app.',
    missions: [
      { title: 'Draw and ship a new icon', started: at(4, 1, 9), closed: at(1, 3, 15), summary: 'The rounded icon shipped in every app.',
        milestones: [[at(4, 1, 13), 'Four icon options drawn'], [at(2, 2, 10), 'The rounded one chosen'], [at(1, 3, 14), 'New icon in every app']],
        items: [{ kind: 'question', title: 'Which of the four icons?', when: at(4, 1, 14), closed: at(2, 2, 10), resolution: 'answered',
          comments: [[at(4, 1, 14), 'The four options.', ['icon-options.png']]] }] },
    ],
  },
];

// What the Coordinator says about each week, one entry per project.
const THIS_WEEK = [
  ['Docs site launch', 'Search on the new site now shows the sentence that matched, and every old address lands on the right guide.',
    'Choose the tab order, then pick a launch day.', 'navigation-bar.png'],
  ['Promo launch', 'The launch page loads in under a second on a phone, and the video has a first cut.',
    'Pick an ending for the video.', 'launch-page.png'],
  ['Search in the mobile apps', 'Search on iPhone remembers recent searches and works offline for chats already on the phone.',
    'Start on the tablet layout.', 'search-on-iphone.png'],
  ['Themes', 'A fourth theme, deep green, joined light, dark and sepia, and the picker previews each one before you choose.', null, 'theme-swatches.png'],
  ['Offline mode', 'A message waiting to send can now be edited or removed.', 'Decide which edit wins when two devices disagree.', 'offline-chat.png'],
  ['Accessibility audit', 'The chat list reads out sender, time and message in that order. Nine of the fourteen findings are fixed.', null, null],
  ['Billing export', 'The monthly statement builds as a file you can print.', 'Check one month against the invoices.', 'statement-layout.png'],
];
const LAST_WEEK = [
  ['Docs site launch', 'The new navigation bar was built and put on the test site, and the launch checklist was written.', 'Test the redirects.', 'guides-home.png'],
  ['Promo launch', 'The launch page was built in light and dark, and the announcement email is scheduled.', 'Cut the video.', 'launch-page-dark.png'],
  ['Search in the mobile apps', 'Tapping a search result opens the chat at that message.', 'Remember recent searches.', null],
  ['Themes', 'The sepia theme for reading arrived, and Settings got a theme picker.', null, 'sepia-reading.png'],
  ['Offline mode', 'Messages written offline now send in order when the connection returns.', null, null],
  ['Billing export', 'The spreadsheet export covers any date range, and the monthly statement has a layout.', 'Build the statement.', null],
  ['New app icon', 'The new rounded icon is in every app. This project is finished.', null, 'icon-options.png'],
  ['Notification settings', 'Muting a chat now carries over to your other devices.', null, null],
];

// ---- Write it all through the journal. ----
const ws = await new Promise((resolve, reject) => {
  let ready = false;
  const w = new WebSocket(`ws://127.0.0.1:${PORT}/ws`);
  w.addEventListener('open', () => w.send(JSON.stringify({ op: 'hello', token: agentToken, cursor: null })));
  w.addEventListener('message', (event) => {
    const msg = JSON.parse(event.data.toString());
    if (msg.op === 'hello_ok') { ready = true; resolve(w); }
    else if (msg.op === 'error') {
      if (!ready) reject(new Error(`hello refused: ${JSON.stringify(msg)}`));
      else { console.error('seed-projects: server error:', msg); process.exit(1); }
    }
  });
  w.addEventListener('error', () => reject(new Error(`no journal on port ${PORT}`)));
});
async function conversation(id, title, state) {
  ws.send(JSON.stringify({ op: 'convo_upsert', convo_id: id, title, session_state: state }));
  await sleep(80);
}

const sql = [];
const q = (text) => `'${String(text).replaceAll("'", "''")}'`;
const projectIDs = new Map();
let convoCount = 0;

for (const p of PROJECTS) {
  const { project } = await post('/projects', { title: p.title });
  projectIDs.set(p.title, project.id);
  let first = Infinity, last = 0;
  for (const m of p.missions) {
    const convo = `demo-projects-${++convoCount}`;
    await conversation(convo, m.title, m.closed ? 'done' : m.state ?? 'done');
    const { mission } = await post('/missions', { title: m.title, convo_id: convo, project: project.id });
    let newest = m.started;
    for (const [when, title] of m.milestones) {
      const { milestone } = await post('/milestones', { convo_id: convo, kind: 'progress', title });
      sql.push(`UPDATE milestones SET created_at=${when} WHERE id=${q(milestone.id)};`);
      newest = Math.max(newest, when);
    }
    for (const it of m.items) {
      const fields = { kind: it.kind, convo_id: convo, title: it.title, body: it.body ?? '' };
      if (it.actions) fields.actions = it.actions;
      if (it.waiting && it.kind === 'task') fields.awaiting = 'user';
      if (!it.waiting && (it.kind === 'question' || it.kind === 'notice')) fields.awaiting = 'agent';
      const { item } = await post('/items', fields);
      let touched = it.when;
      for (const [when, body, names = []] of it.comments) {
        const attachments = [];
        for (const name of names) attachments.push(await fileNamed(name));
        const { comment } = await post(`/items/${item.id}/comments`, { body, attachments });
        sql.push(`UPDATE item_comments SET created_at=${when} WHERE id=${q(comment.id)};`);
        touched = Math.max(touched, when);
      }
      if (it.closed) {
        const resolution = it.resolution ?? (it.kind === 'decision' ? 'decided' : it.kind === 'question' ? 'answered' : 'done');
        await post(`/items/${item.id}/close`, { resolution });
        sql.push(`UPDATE item_comments SET created_at=${it.closed} WHERE item_id=${q(item.id)} AND kind='status';`);
        touched = Math.max(touched, it.closed);
      }
      sql.push(`UPDATE items SET created_at=${it.when}, updated_at=${touched}, closed_at=${it.closed ?? 'NULL'} WHERE id=${q(item.id)};`);
      newest = Math.max(newest, touched);
    }
    if (m.status) await call(agentToken, 'PATCH', `/missions/${mission.id}`, { status: m.status, convo_id: convo });
    if (m.closed) {
      await post(`/missions/${mission.id}/close`, { summary: m.summary, convo_id: convo });
      newest = Math.max(newest, m.closed);
    }
    sql.push(`UPDATE missions SET created_at=${m.started}, updated_at=${newest}, closed_at=${m.closed ?? 'NULL'},
        status_updated_at=CASE WHEN status IS NULL THEN NULL ELSE ${newest} END,
        last_milestone_at=(SELECT MAX(created_at) FROM milestones WHERE mission_id=${q(mission.id)}) WHERE id=${q(mission.id)};`,
      `UPDATE mission_conversations SET joined_at=${m.started}, first_joined_at=${m.started} WHERE mission_id=${q(mission.id)};`,
      `UPDATE conversations SET created_at=${m.started} WHERE id=${q(convo)};`,
      // The chat's own events, spread from the mission's start to its last move.
      `WITH r AS (SELECT user_id, seq, ROW_NUMBER() OVER (ORDER BY seq) - 1 AS i, COUNT(*) OVER () AS n FROM events WHERE convo_id=${q(convo)})
        UPDATE events SET ts=${m.started} + (${newest - m.started}) * r.i / MAX(r.n - 1, 1) FROM r
        WHERE events.user_id=r.user_id AND events.seq=r.seq;`);
    first = Math.min(first, m.started);
    last = Math.max(last, newest);
  }
  if (p.status) await call(agentToken, 'PATCH', `/projects/${project.id}`, { status: p.status });
  // Closing a project is the user's to do (or their Coordinator's).
  if (p.closed) await call(client.token, 'POST', `/projects/${project.id}/close`, { summary: p.summary });
  sql.push(`UPDATE projects SET created_at=${first - 3_600_000}, updated_at=${p.closed ?? last}, closed_at=${p.closed ?? 'NULL'},
      status_updated_at=CASE WHEN status IS NULL THEN NULL ELSE ${last} END WHERE id=${q(project.id)};`);
}

// The Coordinator: a conversation of this agent's that the user names as
// theirs. Only it may write a week.
const COORDINATOR = 'demo-projects-coordinator';
await conversation(COORDINATOR, 'Coordinator', 'done');
await call(client.token, 'PUT', '/coordinator', { convo_id: COORDINATOR });

// Move the rows back in time before the weeks are written, so a week's
// entry finds the pictures and items of its own days.
execFileSync('sqlite3', [DB], { input: `.timeout 5000\nBEGIN;\n${sql.join('\n')}\nCOMMIT;\n` });

const entries = (rows) => rows.map(([title, sentence, next, picture]) => {
  const entry = { project: projectIDs.get(title), sentence };
  if (next) entry.next = next;
  if (picture) entry.media_blob_id = uploads.get(picture).blob_ref;
  return entry;
});
await post(`/timeline/weeks/${weekKey(1)}/entries`, { convo_id: COORDINATOR, entries: entries(LAST_WEEK), final: true });
await post(`/timeline/weeks/${weekKey(0)}/entries`, { convo_id: COORDINATOR, entries: entries(THIS_WEEK) });

ws.close();
console.log(`seeded ${PROJECTS.length} projects, ${convoCount} missions, ${uploads.size} files; wrote weeks ${weekKey(1)} and ${weekKey(0)}`);
