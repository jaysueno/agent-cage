// Builds the two README diagrams in this folder: cage.svg and forward-chain.svg.
// Node built-ins only. Same script, same bytes: no clock, no randomness, no network.
// Shapes are filled rectangles and polygons with plain text, so every SVG renderer draws them
// the same way. Run from the repo root: node docs/img/make.mjs
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT = dirname(fileURLToPath(import.meta.url));

// Four colors and two font stacks, nothing else: navy #001B3B (background), sand #EDE7DC
// (border, arrows), terracotta #8C5348 (blocked), olive #59591D (allowed), with two lighter
// text tones on navy. Titles in Georgia, everything else in the system sans-serif.
const NAVY = '#001B3B';
const SAND = '#EDE7DC';
const TERRACOTTA = '#8C5348';
const OLIVE = '#59591D';
const HEAD = '#F2EDE2';
const SUB = '#D8D3CA';
const SERIF = "Georgia, 'Playfair Display', serif";
const SANS = "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif";

const W = 1200;

// The example uid from cage.env.example (AGENT_UID). Change both together.
const AGENT_UID = 10001;

const esc = (s) =>
  String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function text(x, y, s, o = {}) {
  const a = [`x="${x}"`, `y="${y}"`, `font-family="${o.serif ? SERIF : SANS}"`, `font-size="${o.size || 18}"`];
  if (o.bold) a.push('font-weight="700"');
  if (o.anchor) a.push(`text-anchor="${o.anchor}"`);
  a.push(`fill="${o.fill || SUB}"`);
  return `<text ${a.join(' ')}>${esc(s)}</text>`;
}

function rect(x, y, w, h, fill) {
  return `<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="${fill}"/>`;
}

// A box with a 2px border drawn as two filled rectangles (no stroke).
function box(x, y, w, h, fill, border = SAND) {
  return [rect(x, y, w, h, border), rect(x + 2, y + 2, w - 4, h - 4, fill)];
}

// A horizontal arrow from x1 to x2 at height y: a bar and a triangle head, both filled.
// end = 'head' for a way through, 'block' for a wall the arrow stops at.
function hArrow(x1, x2, y, fill, end = 'head') {
  const t = 4;
  if (end === 'block') {
    return [rect(x1, y - t / 2, x2 - x1 - 8, t, fill), rect(x2 - 8, y - 18, 8, 36, fill)];
  }
  const head = 16;
  return [
    rect(x1, y - t / 2, x2 - x1 - head, t, fill),
    `<polygon points="${x2},${y} ${x2 - head},${y - 9} ${x2 - head},${y + 9}" fill="${fill}"/>`,
  ];
}

function svg(h, title, desc, body) {
  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${h}" viewBox="0 0 ${W} ${h}" role="img" aria-labelledby="title desc">`,
    `<title id="title">${esc(title)}</title>`,
    `<desc id="desc">${esc(desc)}</desc>`,
    rect(0, 0, W, h, SAND),
    rect(1, 1, W - 2, h - 2, NAVY),
    ...body,
    '</svg>',
    '',
  ].join('\n');
}

function cage() {
  const H = 520;
  const b = [];
  b.push(text(40, 58, 'Two doors out. Every other way is rejected.', { serif: true, size: 32, fill: HEAD }));
  b.push(text(40, 90, 'What the agent container can reach, on the host and off it, and what holds it in place.', { size: 19 }));

  // The container.
  b.push(...box(40, 124, 420, 330, NAVY));
  b.push(text(64, 162, 'the agent container', { size: 22, bold: true, fill: HEAD }));
  const inside = [
    `runs as uid ${AGENT_UID}, never root`,
    'read-only root filesystem',
    'every capability dropped',
    'no-new-privileges',
    'memory and process limits',
    'writes: its home, the outbox, /tmp',
    'token read from a file, in process',
  ];
  inside.forEach((s, i) => b.push(text(64, 202 + i * 36, s, { size: 19 })));

  // The three destinations.
  const rows = [
    { y: 124, h: 96, fill: OLIVE, title: 'the proxy on the host', sub: 'one allowlisted chat API host, HTTPS on 443', via: 'ufw: proxy port only' },
    { y: 240, h: 96, fill: OLIVE, title: 'one tailnet host and port', sub: 'your model server, nothing else there', via: 'two rules above Tailscale' },
    { y: 356, h: 98, fill: TERRACOTTA, title: 'everything else: REJECT', sub: 'the internet, the rest of the tailnet,', sub2: 'cloud metadata, the host\'s other ports', via: 'both firewalls: REJECT' },
  ];
  for (const r of rows) {
    b.push(rect(680, r.y, 480, r.h, r.fill));
    b.push(text(704, r.y + 36, r.title, { size: 22, bold: true, fill: HEAD }));
    b.push(text(704, r.y + 66, r.sub, { size: 18, fill: HEAD }));
    if (r.sub2) b.push(text(704, r.y + 88, r.sub2, { size: 18, fill: HEAD }));
    const cy = r.y + r.h / 2;
    const blocked = r.fill === TERRACOTTA;
    b.push(...hArrow(460, 680, cy, blocked ? TERRACOTTA : SAND, blocked ? 'block' : 'head'));
    b.push(text(570, cy - 14, r.via, { size: 16, anchor: 'middle' }));
  }

  b.push(text(40, 494, 'Proved by verify-cage.sh: five fire drills, one PASS or FAIL line each, run on every apply.', { size: 19, fill: HEAD }));

  return svg(
    H,
    'What the caged agent can reach',
    `The agent container runs as uid ${AGENT_UID} on a read-only root with every capability dropped; it can reach only the host proxy, which allows one listed hostname, and one tailnet host and port; every other destination, including the host's other ports, is rejected.`,
    b,
  );
}

function forwardChain() {
  const H = 540;
  const b = [];
  b.push(text(40, 58, "The hole: Tailscale's forward chain sat above Docker's", { serif: true, size: 30, fill: HEAD }));
  b.push(text(40, 90, 'The FORWARD chain, top to bottom, for a packet from the cage to a tailnet machine.', { size: 19 }));

  const col = (x, heading, sub, items) => {
    b.push(text(x, 136, heading, { size: 22, bold: true, fill: HEAD }));
    b.push(text(x, 162, sub, { size: 17 }));
    items.forEach((it, i) => {
      const y = 182 + i * 72;
      if (it.fill === NAVY) b.push(...box(x, y, 520, 60, NAVY, SUB));
      else b.push(rect(x, y, 520, 60, it.fill));
      b.push(text(x + 20, y + 26, `${i + 1}  ${it.rule}`, { size: 19, bold: true, fill: HEAD }));
      b.push(text(x + 44, y + 49, it.note, { size: 16, fill: it.fill === NAVY ? SUB : HEAD }));
    });
  };

  col(40, 'Before', 'found on August 27, 2026', [
    { rule: '-j ts-forward', note: 'accepts everything out tailscale0: the packet ends here', fill: TERRACOTTA },
    { rule: '-j DOCKER-USER', note: "the cage's REJECT: never reached for tailnet traffic", fill: NAVY },
    { rule: "Docker's own chains", note: 'never reached either', fill: NAVY },
  ]);
  col(640, 'After', 'two rules above the jump', [
    { rule: 'ACCEPT  cage to one host:port', note: 'out tailscale0, TCP, one port', fill: OLIVE },
    { rule: 'REJECT  cage to anything else', note: 'out tailscale0', fill: OLIVE },
    { rule: '-j ts-forward', note: "still handles the host's own traffic", fill: NAVY },
    { rule: '-j DOCKER-USER', note: "the cage's egress rules for everything off the tailnet", fill: NAVY },
  ]);

  b.push(text(40, 488, 'tailscaled puts its jump back at position 1 every time it starts.', { size: 19, fill: HEAD }));
  b.push(text(40, 516, 'tailnet-guard.sh restores the order every 60 seconds, at boot, and 5 seconds after tailscaled starts.', { size: 19, fill: HEAD }));

  return svg(
    H,
    "Tailscale's forward chain above Docker's",
    'Before the fix, the FORWARD chain sent cage traffic to Tailscale first, which accepted every packet bound for the tailnet before the cage rule in DOCKER-USER could reject it; after the fix, two cage rules sit above the Tailscale jump and a guard re-asserts them every 60 seconds.',
    b,
  );
}

writeFileSync(join(OUT, 'cage.svg'), cage());
writeFileSync(join(OUT, 'forward-chain.svg'), forwardChain());
console.log('wrote cage.svg and forward-chain.svg');
