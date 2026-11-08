// A small reader for compose.yaml that checks the cage's hardening in every service. It reads
// the block style this repo uses (services at two spaces, keys at four); it is not a general
// YAML parser, and compose.test.mjs proves it catches each weakness before trusting a verdict.

export function services(text) {
  const out = {};
  let inServices = false;
  let name = null;
  let key = null;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\s+#.*$/, '').replace(/^\s*#.*$/, '');
    if (!line.trim()) continue;
    const indent = line.length - line.trimStart().length;
    if (indent === 0) {
      inServices = line.startsWith('services:');
      name = null;
      continue;
    }
    if (!inServices) continue;
    if (indent === 2 && /^\s{2}[\w.-]+:\s*$/.test(line)) {
      name = line.trim().slice(0, -1);
      out[name] = {};
      key = null;
      continue;
    }
    if (!name) continue;
    if (indent === 4) {
      const m = line.trim().match(/^([\w.-]+):\s*(.*)$/);
      if (m) {
        key = m[1];
        out[name][key] = { value: m[2], items: [] };
      }
      continue;
    }
    if (key && indent > 4) out[name][key].items.push(line.trim().replace(/^-\s*/, ''));
  }
  return out;
}

const unquote = (s) => s.replace(/^["']|["']$/g, '');

export function lint(text) {
  const problems = [];
  const svcs = services(text);
  if (!Object.keys(svcs).length) problems.push('compose:NO_SERVICES');
  for (const [name, k] of Object.entries(svcs)) {
    const bad = (item) => problems.push(`${name}:${item}`);
    const val = (key) => (k[key] ? unquote(k[key].value) : undefined);
    const all = (key) => (k[key] ? [k[key].value, ...k[key].items].join(' ') : '');
    if (val('read_only') !== 'true') bad('READ_ONLY');
    if (!/\bALL\b/.test(all('cap_drop'))) bad('CAP_DROP_ALL');
    if (!/no-new-privileges(:true)?\b/.test(all('security_opt')) || /no-new-privileges[:=]false/.test(all('security_opt')))
      bad('NO_NEW_PRIVILEGES');
    if (!val('mem_limit')) bad('MEM_LIMIT');
    if (!/^[1-9][0-9]*$/.test(val('pids_limit') || '')) bad('PIDS_LIMIT');
    const user = val('user');
    if (!user || /^(root|0)(:|$)/.test(user)) bad('NON_ROOT_USER');
    if (val('privileged') === 'true') bad('PRIVILEGED');
    if (k.cap_add) bad('CAP_ADD');
    for (const ns of ['network_mode', 'pid', 'ipc']) if (val(ns) === 'host') bad(`HOST_${ns.toUpperCase()}`);
    if (k.env_file) bad('ENV_FILE');
    if (k.ports) bad('PORTS');
    if (/docker\.sock/.test(all('volumes'))) bad('DOCKER_SOCK');
    if (/unconfined/.test(all('security_opt'))) bad('UNCONFINED');
    for (const v of k.volumes ? k.volumes.items : []) {
      if (/(token|entrypoint\.sh|verify-cage\.sh)/i.test(v) && !/:ro$/.test(unquote(v))) bad('WRITABLE_MOUNT');
    }
  }
  return problems;
}
