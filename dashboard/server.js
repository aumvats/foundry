#!/usr/bin/env node
// Foundry Dashboard — zero npm dependencies, pure Node.js built-ins

const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync, spawn } = require('child_process');

const PORT = 4040;
const FOUNDRY_DIR = path.join(__dirname, '..');
const PROJECTS_JSON = path.join(FOUNDRY_DIR, 'projects.json');
const LOGS_DIR = path.join(FOUNDRY_DIR, 'logs');

const BUILD_AGENTS = [
  { id: 'planner',   label: 'Plan',     verb: 'Planning architecture'   },
  { id: 'builder',   label: 'Build',    verb: 'Writing full codebase'   },
  { id: 'qa',        label: 'QA',       verb: 'Reviewing & fixing code' },
  { id: 'designer',  label: 'Design',   verb: 'Polishing the UI'        },
  { id: 'optimizer', label: 'Optimise', verb: 'Tuning performance'      },
];

const SPEC_STAGES = [
  { id: 'ideating',   label: 'Generating' },
  { id: 'critiquing', label: 'Critiquing' },
  { id: 'refining',   label: 'Refining'   },
  { id: 'validating', label: 'Validating' },
];

// ── Helpers ───────────────────────────────────────────────────────────────────

function readJSON(f) { try { return JSON.parse(fs.readFileSync(f,'utf8')); } catch { return null; } }

function readTail(file, n = 250) {
  try {
    if (!fs.existsSync(file)) return [];
    return fs.readFileSync(file,'utf8').split('\n').filter(Boolean).slice(-n);
  } catch { return []; }
}

function stripAnsi(s) { return s.replace(/\x1B\[[0-9;]*[mGKHF]/g,''); }

function cleanMd(s) {
  if (!s) return s;
  return s.replace(/\*\*(.*?)\*\*/g,'$1').replace(/_(.*?)_/g,'$1').replace(/`(.*?)`/g,'$1').trim();
}

function cleanName(raw) {
  if (!raw) return raw;
  const parts = raw.split(/\s+[—–-]+\s+/);
  if (parts.length >= 2) {
    if (parts[0].match(/^PROJECT-\d+/i)) return cleanMd(parts[1]);
    return cleanMd(parts[0]);
  }
  return cleanMd(raw);
}

function todayLog(name) {
  return path.join(LOGS_DIR, `${name}-${new Date().toISOString().slice(0,10)}.md`);
}

function isRunning(scripts) {
  try {
    const ps = execSync('ps aux',{encoding:'utf8'});
    return ps.split('\n').some(l => scripts.some(s => l.includes(s) && !l.includes('grep') && !l.includes('bash -n')));
  } catch { return false; }
}

function fmtSecs(s) {
  const n = parseInt(s);
  if (isNaN(n)) return '';
  if (n < 60) return `${n}s`;
  return `${Math.round(n/60)}m`;
}

// ── Log Parsing ───────────────────────────────────────────────────────────────

function extractBuildState(lines) {
  let projectId = null, completedAgents = [], currentAgent = null;
  for (const raw of lines) {
    const l = stripAnsi(raw);
    // Detect project from orchestrate.sh run
    const bm = l.match(/\[orchestrate\].*Building:\s*(project-\S+)/i);
    if (bm) { projectId = bm[1]; completedAgents = []; currentAgent = null; }
    // Detect project from direct build-project.sh run (Dir line)
    const dm2 = l.match(/Dir:\s+.*\/(project-[\w-]+)/);
    if (dm2 && !projectId) { projectId = dm2[1]; completedAgents = []; currentAgent = null; }
    // "Skipping X (resuming from Y)" — treat skipped agents as already completed
    const sm = l.match(/Skipping (\w+) \(resuming/i);
    if (sm) {
      const s = sm[1].toLowerCase();
      if (BUILD_AGENTS.find(a=>a.id===s) && !completedAgents.includes(s)) completedAgents.push(s);
    }
    const am = l.match(/── Agent: (\w+) ──/);
    if (am) currentAgent = am[1];
    const dm = l.match(/✓.*?(\w+) agent complete/i);
    if (dm) {
      const d = dm[1].toLowerCase();
      if (BUILD_AGENTS.find(a=>a.id===d) && !completedAgents.includes(d)) completedAgents.push(d);
      if (currentAgent === d) currentAgent = null;
    }
    if (l.match(/Build verified after optimizer/)) { completedAgents = BUILD_AGENTS.map(a=>a.id); currentAgent = null; }
    if (l.match(/BUILD COMPLETE/)) { completedAgents = BUILD_AGENTS.map(a=>a.id); currentAgent = null; }
  }
  return { projectId, currentAgent, completedAgents };
}

function extractSpecState(lines) {
  let attempt=null, maxAttempts=null, queued=null, target=null, stage=null;
  for (const raw of lines) {
    const l = stripAnsi(raw);
    const m = l.match(/Attempt (\d+)\/(\d+) \(queued: (\d+)\/(\d+)\)/);
    if (m) { attempt=+m[1]; maxAttempts=+m[2]; queued=+m[3]; target=+m[4]; }
    if (l.includes('Running ideator'))   stage='ideating';
    if (l.includes('Running critic'))    stage='critiquing';
    if (l.includes('Running refiner'))   stage='refining';
    if (l.includes('Running validator')) stage='validating';
    if (l.includes('Spec Pipeline complete')) stage='complete';
  }
  return { attempt, maxAttempts, queued, target, stage };
}

function getTodayStats(specLines, buildLines, projects) {
  let specsRun=0, kills=0, rewrites=0, queuedToday=0, builtToday=0;
  for (const raw of specLines) {
    const l = stripAnsi(raw);
    if (l.match(/Running ideator/)) specsRun++;
    if (l.match(/Critic: KILL/))   kills++;
    if (l.match(/Critic: REWRITE/)) rewrites++;
    if (l.match(/→ QUEUED for build/)) queuedToday++;
  }
  for (const raw of buildLines) {
    const l = stripAnsi(raw);
    if (l.match(/Build verified after optimizer/)) builtToday++;
  }
  return { specsRun, kills, rewrites, queuedToday, builtToday,
    totalBuilt: projects.filter(p=>['built','deployed','live'].includes(p.status)).length,
    totalDeployed: projects.filter(p=>p.status==='deployed'||p.status==='live').length };
}

function parseActivity(lines, source) {
  const events = [];
  for (const raw of lines) {
    const l = stripAnsi(raw);
    let msg=null, type='info', detail=null;

    if      (l.match(/── Agent: planner/))   { msg='Planning product architecture';               type='agent'; }
    else if (l.match(/── Agent: builder/))   { msg='Writing the full codebase';                   type='agent'; }
    else if (l.match(/── Agent: qa/))        { msg='QA reviewing and fixing code';                type='agent'; }
    else if (l.match(/── Agent: designer/))  { msg='Designer polishing the UI';                   type='agent'; }
    else if (l.match(/── Agent: optimizer/)) { msg='Optimising performance & accessibility';       type='agent'; }
    else if (l.match(/planner agent complete/i))   { const s=l.match(/\((\d+)s\)/); msg=`Architecture planned`; detail=s?fmtSecs(s[1]):null; type='ok'; }
    else if (l.match(/builder agent complete/i))   { const s=l.match(/\((\d+)s\)/); msg=`Codebase written`;     detail=s?fmtSecs(s[1]):null; type='ok'; }
    else if (l.match(/qa agent complete/i))        { const s=l.match(/\((\d+)s\)/); msg=`Code reviewed & fixed`;detail=s?fmtSecs(s[1]):null; type='ok'; }
    else if (l.match(/designer agent complete/i))  { const s=l.match(/\((\d+)s\)/); msg=`UI design applied`;   detail=s?fmtSecs(s[1]):null; type='ok'; }
    else if (l.match(/optimizer agent complete/i)) { const s=l.match(/\((\d+)s\)/); msg=`Performance tuned`;   detail=s?fmtSecs(s[1]):null; type='ok'; }
    else if (l.match(/Build verified after builder/))  { msg='Build compiles clean'; type='ok'; }
    else if (l.match(/Build verified after optimizer/))  { msg='Final build passed — product ready'; type='ok'; }
    else if (l.match(/Running ideator/))    { msg='Generating new product idea'; type='info'; }
    else if (l.match(/Ideator complete/))   { const s=l.match(/\([\s\d]+ bytes\)/); msg='Spec written'; detail=s?s[0].replace(/[()]/g,''):null; type='ok'; }
    else if (l.match(/Running critic/))     { msg='Critic reviewing the idea'; type='info'; }
    else if (l.match(/Critic: PROCEED/))    { msg='Idea approved by Critic'; type='ok'; }
    else if (l.match(/Critic: REWRITE/))    { msg='Idea needs improvement — refining'; type='warn'; }
    else if (l.match(/Critic: KILL/))       {
      const score = l.match(/(\d+)\/50/);
      msg='Idea rejected, trying again'; detail=score?`${score[1]}/50`:null; type='fail';
    }
    else if (l.match(/Running refiner/))    { msg='Refiner improving the spec'; type='info'; }
    else if (l.match(/Refiner complete/))   { msg='Spec refined and strengthened'; type='ok'; }
    else if (l.match(/Running validator/))  { msg='Validating 30+ quality criteria'; type='info'; }
    else if (l.match(/→ QUEUED for build/)) { msg='Spec approved — queued for build'; type='ok'; }
    else if (l.match(/Spec Pipeline complete/)) {
      const m=l.match(/(\d+)\/(\d+) queued/);
      msg=m?`Done — ${m[1]} of ${m[2]} ideas approved`:'Spec pipeline complete'; type='ok';
    }
    else if (l.match(/Pre-flight checks passed/)) { msg='Pre-flight checks passed'; type='ok'; }
    else if (l.match(/AUTH FAILED/i))   { msg='Auth failed — Claude CLI needs login'; type='fail'; }
    else if (l.match(/build_failed/i))  { msg='Build failed — flagged for review'; type='fail'; }
    else if (l.match(/status.*built/i) && source==='build') { msg='Product built successfully!'; type='ok'; }

    if (msg) events.push({ msg, type, source, detail });
  }
  return events;
}

// ── Rules Parsing ─────────────────────────────────────────────────────────────

function parseRuleProposals() {
  const proposals = [];
  let files = [];
  try {
    files = fs.readdirSync(LOGS_DIR)
      .filter(f => f.match(/^rule-proposals-.*\.md$/))
      .map(f => path.join(LOGS_DIR, f));
  } catch { return proposals; }

  for (const filePath of files) {
    let content = '';
    try { content = fs.readFileSync(filePath, 'utf8'); } catch { continue; }

    const sections = content.split(/^### /m).filter(Boolean);
    for (const section of sections) {
      const lines = section.split('\n');
      const heading = lines[0].trim();
      const body = lines.slice(1).join('\n');

      const colonIdx = heading.indexOf(':');
      const ruleId   = colonIdx > -1 ? heading.slice(0, colonIdx).trim() : heading;
      const ruleName = heading;

      const extract = (label) => {
        const m = body.match(new RegExp(`\\*\\*${label}:\\*\\*\\s*(.+)`));
        return m ? m[1].trim() : '';
      };

      // Skip non-proposal sections (e.g. ## file headers that ended up in split)
      if (!heading || heading.startsWith('#')) continue;

      proposals.push({
        ruleId,
        ruleName,
        pattern:        extract('Pattern'),
        agent:          extract('Agent'),
        appendToPrompt: extract('append_to_prompt'),
        confidence:     extract('Confidence'),
        status:         extract('Status'),
        sourceFile:     path.basename(filePath),
      });
    }
  }
  return proposals;
}

// ── Status ────────────────────────────────────────────────────────────────────

function getStatus() {
  const data = readJSON(PROJECTS_JSON);
  const projects = (data?.projects || []).map(p => ({
    ...p,
    displayName: cleanName(p.name) || p.id,
    displayTagline: cleanMd(p.tagline || ''),
  }));

  const specLogFile = (() => {
    const dated = todayLog('spec-creation');
    const plain  = path.join(LOGS_DIR,'spec-creation.log');
    try {
      const dm = fs.existsSync(dated) ? fs.statSync(dated).mtimeMs : 0;
      const pm = fs.existsSync(plain) ? fs.statSync(plain).mtimeMs : 0;
      return dm >= pm ? dated : plain;
    } catch { return dated; }
  })();

  const buildLogFile   = path.join(LOGS_DIR,'cron.log');
  const evolverLogFile = path.join(LOGS_DIR,'evolver.log');

  const specLines    = readTail(specLogFile, 250);
  const buildLines   = readTail(buildLogFile, 250);
  const evolverLines = readTail(evolverLogFile, 100);

  const specRunning  = isRunning(['create-spec.sh']);
  const buildRunning = isRunning(['orchestrate.sh','build-project.sh']);

  const buildState = extractBuildState(buildLines);
  const specState  = extractSpecState(specLines);

  // Fallback: infer building project from projects.json status
  if (buildRunning && !buildState.projectId) {
    const bp = projects.find(p=>p.status==='building');
    if (bp) buildState.projectId = bp.id;
  }

  const buildProjectName = buildState.projectId
    ? (projects.find(p=>p.id===buildState.projectId)?.displayName || buildState.projectId)
    : null;

  // Alerts — last 24h only
  const cutoff = Date.now() - 86400000;
  const alerts = readTail(path.join(LOGS_DIR,'alerts.log'), 20)
    .filter(Boolean)
    .filter(l => { const m=l.match(/\w+ \w+ +\d+ \d+:\d+:\d+ \w+ \d+/); if(!m) return false; try{return new Date(m[0]).getTime()>cutoff;}catch{return false;} })
    .slice(-4);

  const todayStats = getTodayStats(specLines, buildLines, projects);

  const specEvents  = parseActivity(specLines,  'spec');
  const buildEvents = parseActivity(buildLines, 'build');
  const activity = [...specEvents, ...buildEvents]
    .slice(-60);

  return {
    projects,
    specRunning, buildRunning,
    buildState: { ...buildState, projectName: buildProjectName },
    specState,
    todayStats,
    activity,
    specLogLines:    specLines.map(stripAnsi),
    buildLogLines:   buildLines.map(stripAnsi),
    evolverLogLines: evolverLines.map(stripAnsi),
    alerts,
    ts: new Date().toISOString(),
  };
}

// ── SSE ───────────────────────────────────────────────────────────────────────

const clients = new Set();
function broadcast(d) {
  const p = `data: ${JSON.stringify(d)}\n\n`;
  for (const r of clients) { try { r.write(p); } catch { clients.delete(r); } }
}
setInterval(() => { try { broadcast(getStatus()); } catch {} }, 2000);

// ── HTML ──────────────────────────────────────────────────────────────────────

const HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Foundry</title>
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Cormorant+Garamond:ital,wght@0,300;0,400;0,500;0,600;0,700;1,300;1,400;1,500&family=JetBrains+Mono:wght@400;500;700&display=swap" rel="stylesheet">
<style>
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

:root {
  --bg:        #0B0906;
  --surface:   #131008;
  --surface2:  #1A1510;
  --surface3:  #221C14;
  --border:    #2A2218;
  --border2:   #382E20;
  --text:      #EDE8DC;
  --text2:     #9A8870;
  --text3:     #5C5040;
  --ch:        #C5E823;
  --ch-dim:    #3A4709;
  --amber:     #D4882A;
  --amb-dim:   #5C3A0A;
  --red:       #E05050;
  --red-dim:   #4A1A1A;
  --blue:      #5590D0;
  --blue-dim:  #1A3A5C;
  --purple:    #9B70E8;
  --ff-serif: 'Cormorant Garamond', Georgia, serif;
  --ff-mono:  'JetBrains Mono', 'Courier New', monospace;
}

html, body { height: 100%; overflow: hidden; }
body {
  background: var(--bg);
  color: var(--text);
  font-family: var(--ff-serif);
  font-size: 15px;
  line-height: 1.5;
}

/* ─── HEADER ──────────────────────────────────────────────── */
header {
  height: 44px;
  display: flex;
  align-items: center;
  justify-content: space-between;
  padding: 0 24px;
  border-bottom: 1px solid var(--border);
  background: var(--surface);
  position: relative;
  z-index: 10;
  flex-shrink: 0;
}
.masthead {
  font-family: var(--ff-serif);
  font-size: 13px;
  font-weight: 700;
  letter-spacing: 0.32em;
  text-transform: uppercase;
  color: var(--text);
  display: flex;
  align-items: center;
  gap: 10px;
}
.masthead-pip {
  width: 5px; height: 5px;
  background: var(--ch);
  border-radius: 50%;
  flex-shrink: 0;
}
.header-right { display: flex; align-items: center; gap: 24px; }
#conn-status {
  font-family: var(--ff-mono);
  font-size: 10px;
  font-weight: 500;
  letter-spacing: 0.1em;
  display: flex;
  align-items: center;
  gap: 6px;
}
#conn-status.live { color: var(--ch); }
#conn-status.dead { color: var(--red); }
.conn-dot {
  width: 5px; height: 5px;
  border-radius: 50%;
  background: currentColor;
}
.conn-dot.pulse { animation: dotPulse 2s ease-in-out infinite; }
@keyframes dotPulse { 0%,100%{opacity:1} 50%{opacity:.2} }
#ts {
  font-family: var(--ff-mono);
  font-size: 11px;
  color: var(--text3);
  letter-spacing: 0.05em;
}

/* ─── LAYOUT ──────────────────────────────────────────────── */
main {
  display: grid;
  grid-template-columns: 272px 1fr;
  height: calc(100vh - 44px);
}

/* ─── SIDEBAR ─────────────────────────────────────────────── */
aside {
  border-right: 1px solid var(--border);
  overflow-y: auto;
  overflow-x: hidden;
  display: flex;
  flex-direction: column;
  scrollbar-width: thin;
  scrollbar-color: var(--border2) transparent;
}
aside::-webkit-scrollbar { width: 2px; }
aside::-webkit-scrollbar-thumb { background: var(--border2); }

.eyebrow {
  font-family: var(--ff-mono);
  font-size: 9px;
  font-weight: 700;
  letter-spacing: 0.2em;
  text-transform: uppercase;
  color: var(--text3);
}

/* ─── NOW SECTION ─────────────────────────────────────────── */
.now-section {
  padding: 16px 16px 14px;
  border-bottom: 1px solid var(--border);
}
.now-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
  margin-bottom: 14px;
}
.now-status {
  font-family: var(--ff-mono);
  font-size: 9px;
  font-weight: 700;
  letter-spacing: 0.15em;
  text-transform: uppercase;
  padding: 3px 8px;
}
.ns-idle     { color: var(--text3); background: var(--surface3); }
.ns-building { color: var(--amber); background: var(--amb-dim); }
.ns-spec     { color: var(--purple); background: rgba(155,112,232,.12); }

.idle-msg {
  font-style: italic;
  font-size: 17px;
  color: var(--text2);
  line-height: 1.4;
}
.idle-sub {
  font-family: var(--ff-mono);
  font-size: 10px;
  color: var(--text3);
  margin-top: 6px;
}

.build-name {
  font-size: 22px;
  font-weight: 600;
  color: var(--text);
  letter-spacing: -0.02em;
  line-height: 1.2;
  margin-bottom: 4px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}
.build-verb {
  font-family: var(--ff-mono);
  font-size: 10px;
  color: var(--amber);
  letter-spacing: 0.05em;
  margin-bottom: 16px;
}

.pipeline { display: flex; align-items: center; }
.pip-step {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 4px;
  flex: 1;
}
.pip-node {
  width: 28px; height: 28px;
  display: flex;
  align-items: center;
  justify-content: center;
  font-family: var(--ff-mono);
  font-size: 10px;
  font-weight: 700;
  transition: all 0.3s;
}
.pip-node.done   { background: var(--ch-dim); border: 1px solid var(--ch); color: var(--ch); }
.pip-node.done::after { content: '✓'; }
.pip-node.done span { display: none; }
.pip-node.active { background: var(--amb-dim); border: 1px solid var(--amber); color: var(--amber); animation: nodeActive 2s ease-in-out infinite; }
@keyframes nodeActive { 0%,100%{box-shadow:0 0 0 3px rgba(212,136,42,.08)} 50%{box-shadow:0 0 0 6px rgba(212,136,42,.16)} }
.pip-node.pending { background: var(--surface3); border: 1px solid var(--border2); color: var(--text3); }
.pip-lbl {
  font-family: var(--ff-mono);
  font-size: 8px;
  font-weight: 500;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--text3);
}
.pip-lbl.done   { color: var(--ch); opacity: 0.6; }
.pip-lbl.active { color: var(--amber); }
.pip-connector { flex: 1; height: 1px; background: var(--border2); margin-bottom: 16px; transition: background 0.4s; }
.pip-connector.done { background: rgba(197,232,35,.3); }

.spec-headline { font-size: 20px; font-weight: 500; font-style: italic; color: var(--text); margin-bottom: 4px; }
.spec-meta { font-family: var(--ff-mono); font-size: 10px; color: var(--text3); margin-bottom: 14px; }
.spec-stages { display: flex; gap: 4px; flex-wrap: wrap; }
.spec-pill {
  font-family: var(--ff-mono);
  font-size: 9px;
  font-weight: 500;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  padding: 3px 10px;
  border: 1px solid var(--border2);
  color: var(--text3);
  transition: all 0.3s;
}
.spec-pill.done   { border-color: rgba(197,232,35,.25); color: var(--ch); opacity: 0.6; }
.spec-pill.active { border-color: rgba(155,112,232,.4); color: var(--purple); animation: specPulse 1.8s ease-in-out infinite; }
@keyframes specPulse { 0%,100%{opacity:1} 50%{opacity:.45} }

/* ─── STATS ───────────────────────────────────────────────── */
.stats-section {
  padding: 16px;
  border-bottom: 1px solid var(--border);
  display: grid;
  grid-template-columns: repeat(3, 1fr);
  gap: 8px;
}
.stat { text-align: center; }
.stat-n {
  font-family: var(--ff-serif);
  font-size: 44px;
  font-weight: 300;
  line-height: 1;
  letter-spacing: -0.03em;
  margin-bottom: 3px;
}
.stat-n.ch  { color: var(--ch); }
.stat-n.amb { color: var(--amber); }
.stat-n.dim { color: var(--text3); }
.stat-lbl {
  font-family: var(--ff-mono);
  font-size: 8px;
  font-weight: 500;
  letter-spacing: 0.14em;
  text-transform: uppercase;
  color: var(--text3);
}

/* ─── PROJECTS ────────────────────────────────────────────── */
.projects-section { flex: 1; padding: 14px 16px; }
.section-head { display: flex; align-items: center; justify-content: space-between; margin-bottom: 10px; }
.proj-list { display: flex; flex-direction: column; gap: 1px; }

.proj-row {
  padding: 9px 8px;
  border: 1px solid transparent;
  border-left: 2px solid transparent;
  transition: all 0.15s;
  cursor: default;
}
.proj-row:hover { background: var(--surface2); border-color: var(--border); border-left-color: var(--border2); }
.proj-row.is-active { border-left-color: var(--amber); background: rgba(212,136,42,.04); }
.proj-row.is-live   { border-left-color: var(--ch); }

.proj-row-top { display: flex; align-items: baseline; gap: 8px; margin-bottom: 2px; }
.proj-row-name {
  font-size: 15px;
  font-weight: 600;
  color: var(--text);
  flex: 1;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  letter-spacing: -0.01em;
}
.proj-row-name a { color: inherit; text-decoration: none; }
.proj-row-name a:hover { color: var(--ch); }
.proj-row-tag {
  font-size: 12px;
  font-style: italic;
  color: var(--text3);
  line-height: 1.3;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

.badge {
  font-family: var(--ff-mono);
  font-size: 8px;
  font-weight: 700;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  padding: 2px 7px;
  white-space: nowrap;
  flex-shrink: 0;
}
.b-live     { color: var(--ch);     border: 1px solid rgba(197,232,35,.3); }
.b-built    { color: var(--blue);   border: 1px solid rgba(85,144,208,.25); }
.b-queued   { color: var(--amber);  border: 1px solid rgba(212,136,42,.3); }
.b-building { color: var(--amber);  border: 1px solid rgba(212,136,42,.4); }
.b-review   { color: var(--red);    border: 1px solid rgba(224,80,80,.3); }
.b-default  { color: var(--text3);  border: 1px solid var(--border2); }

.deploy-btn {
  font-family: var(--ff-mono);
  font-size: 8px;
  font-weight: 700;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  padding: 2px 9px;
  color: var(--amber);
  border: 1px solid rgba(212,136,42,.4);
  background: transparent;
  cursor: pointer;
  transition: all 0.15s;
  flex-shrink: 0;
}
.deploy-btn:hover { background: var(--amb-dim); border-color: var(--amber); }
.deploy-btn:disabled { opacity: 0.35; cursor: default; }

.mini-bar { display: flex; gap: 2px; margin-top: 6px; }
.mini-seg { height: 2px; flex: 1; background: var(--border2); transition: background 0.3s; }
.mini-seg.done   { background: var(--ch); opacity: 0.5; }
.mini-seg.active { background: var(--amber); animation: segPulse 1.5s ease-in-out infinite; }
@keyframes segPulse { 0%,100%{opacity:1} 50%{opacity:.3} }

.alerts-strip {
  padding: 10px 16px 12px;
  border-top: 1px solid var(--red-dim);
}
.alerts-hd {
  font-family: var(--ff-mono);
  font-size: 8px;
  font-weight: 700;
  letter-spacing: 0.15em;
  text-transform: uppercase;
  color: var(--red);
  opacity: 0.6;
  margin-bottom: 6px;
}
.alert-line { font-family: var(--ff-mono); font-size: 10px; color: var(--red); opacity: 0.5; padding: 2px 0; }

/* ─── RIGHT PANEL ─────────────────────────────────────────── */
.right { display: flex; flex-direction: column; overflow: hidden; }

.tab-bar {
  display: flex;
  align-items: center;
  height: 40px;
  padding: 0 20px;
  border-bottom: 1px solid var(--border);
  background: var(--surface);
  gap: 2px;
  flex-shrink: 0;
}
.tab {
  font-family: var(--ff-mono);
  font-size: 10px;
  font-weight: 500;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  padding: 5px 12px;
  color: var(--text3);
  border: none;
  border: 1px solid transparent;
  background: transparent;
  cursor: pointer;
  transition: color 0.15s;
}
.tab:hover:not(.active) { color: var(--text2); }
.tab.active { color: var(--text); background: var(--surface3); border-color: var(--border2); }
.tab-spacer { flex: 1; }
.tab-count { font-family: var(--ff-mono); font-size: 10px; color: var(--text3); letter-spacing: 0.05em; }

/* ─── PANELS ──────────────────────────────────────────────── */
.panel {
  flex: 1;
  overflow-y: auto;
  overflow-x: hidden;
  scrollbar-width: thin;
  scrollbar-color: var(--border2) transparent;
  min-height: 0;
}
.panel::-webkit-scrollbar { width: 2px; }
.panel::-webkit-scrollbar-thumb { background: var(--border2); }

/* ─── ACTIVITY FEED ───────────────────────────────────────── */
#feed-panel { display: flex; flex-direction: column; }

.feed-empty {
  flex: 1;
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  color: var(--text3);
  font-style: italic;
  font-size: 16px;
  gap: 8px;
  padding: 60px;
}
.feed-empty-icon { font-size: 22px; opacity: 0.25; }

.ev-row {
  display: grid;
  grid-template-columns: 40px 16px 1fr auto 52px;
  align-items: baseline;
  gap: 10px;
  padding: 9px 20px 9px 18px;
  border-bottom: 1px solid var(--border);
  border-left: 2px solid transparent;
  transition: background 0.12s;
}
.ev-row:hover { background: var(--surface2); }
.ev-row.ok    { border-left-color: var(--ch); }
.ev-row.warn  { border-left-color: var(--amber); }
.ev-row.fail  { border-left-color: var(--red); }
.ev-row.agent { border-left-color: var(--blue); background: rgba(85,144,208,.018); }
.ev-row.info  { border-left-color: var(--border2); }

.ev-time { font-family: var(--ff-mono); font-size: 10px; color: var(--text3); letter-spacing: 0.04em; flex-shrink: 0; }
.ev-icon { font-family: var(--ff-mono); font-size: 11px; text-align: center; flex-shrink: 0; }
.ev-row.ok    .ev-icon { color: var(--ch); }
.ev-row.warn  .ev-icon { color: var(--amber); }
.ev-row.fail  .ev-icon { color: var(--red); }
.ev-row.agent .ev-icon { color: var(--blue); }
.ev-row.info  .ev-icon { color: var(--text3); }
.ev-msg { font-size: 14px; color: var(--text); line-height: 1.35; }
.ev-detail { font-family: var(--ff-mono); font-size: 10px; color: var(--text3); text-align: right; flex-shrink: 0; }
.ev-src {
  font-family: var(--ff-mono);
  font-size: 9px;
  font-weight: 700;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  text-align: right;
  flex-shrink: 0;
}
.ev-src.spec  { color: rgba(155,112,232,.45); }
.ev-src.build { color: rgba(212,136,42,.45); }

.cursor {
  display: inline-block;
  width: 5px; height: 12px;
  background: var(--amber);
  margin-left: 3px;
  vertical-align: text-bottom;
  animation: blink 1s step-end infinite;
}
@keyframes blink { 50%{opacity:0} }

/* ─── RAW LOG ─────────────────────────────────────────────── */
#raw-panel { padding: 16px 20px 20px; font-family: var(--ff-mono); font-size: 11px; line-height: 1.75; }
.ll { white-space: pre-wrap; word-break: break-all; color: var(--text3); }
.ll.ok   { color: var(--ch); opacity: 0.75; }
.ll.warn { color: var(--amber); }
.ll.fail { color: var(--red); }
.ll.info { color: var(--blue); opacity: 0.65; }
.ll.dim  { color: var(--border2); }

/* ─── HISTORY PANEL ───────────────────────────────────────── */
#history-panel { display: flex; flex-direction: column; }

.hist-date-sep {
  font-family: var(--ff-mono);
  font-size: 9px;
  font-weight: 700;
  letter-spacing: 0.2em;
  text-transform: uppercase;
  color: var(--text3);
  padding: 12px 20px 8px;
  border-bottom: 1px solid var(--border);
  position: sticky;
  top: 0;
  background: var(--bg);
  z-index: 2;
}

.hev {
  display: grid;
  grid-template-columns: 40px 20px 1fr auto 130px;
  align-items: baseline;
  gap: 10px;
  padding: 8px 20px 8px 18px;
  border-bottom: 1px solid var(--border);
  border-left: 2px solid transparent;
  transition: background 0.12s;
}
.hev:hover { background: var(--surface2); }
.hev.hev-green  { border-left-color: rgba(197,232,35,.4); }
.hev.hev-red    { border-left-color: rgba(224,80,80,.4); }
.hev.hev-amber  { border-left-color: rgba(212,136,42,.4); }
.hev.hev-blue   { border-left-color: rgba(85,144,208,.4); }
.hev.hev-purple { border-left-color: rgba(155,112,232,.4); }
.hev.hev-deploy { border-left-color: var(--ch); background: rgba(197,232,35,.018); }

.hev-time    { font-family: var(--ff-mono); font-size: 10px; color: var(--text3); }
.hev-icon    { font-family: var(--ff-mono); font-size: 11px; }
.hev-msg     { font-size: 14px; color: var(--text); }
.hev-project { font-family: var(--ff-mono); font-size: 9px; color: var(--text3); text-align: right; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.hev-detail  { font-family: var(--ff-mono); font-size: 10px; color: var(--text3); text-align: right; white-space: nowrap; }
.hev-detail a { color: var(--ch); text-decoration: none; }
.hev-detail a:hover { text-decoration: underline; }

/* ─── RULES PANEL ─────────────────────────────────────────── */
#rules-panel { padding: 20px; display: flex; flex-direction: column; gap: 10px; }

.rule-card {
  border: 1px solid var(--border);
  border-left: 3px solid rgba(155,112,232,.35);
  padding: 14px 16px;
  transition: border-color 0.2s;
}
.rule-card:hover { border-color: var(--border2); }
.rule-top { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
.rule-name { font-size: 17px; font-weight: 600; color: var(--text); flex: 1; letter-spacing: -0.01em; }
.rule-conf {
  font-family: var(--ff-mono);
  font-size: 8px;
  font-weight: 700;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  padding: 2px 8px;
}
.rule-conf.high   { color: var(--ch);     border: 1px solid rgba(197,232,35,.3); }
.rule-conf.medium { color: var(--amber);  border: 1px solid rgba(212,136,42,.3); }
.rule-conf.low    { color: var(--text3);  border: 1px solid var(--border2); }
.rule-agent-tag {
  font-family: var(--ff-mono);
  font-size: 8px;
  font-weight: 700;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  padding: 2px 8px;
  color: var(--purple);
  border: 1px solid rgba(155,112,232,.25);
}
.rule-pattern { font-size: 13px; font-style: italic; color: var(--text2); margin-bottom: 10px; line-height: 1.5; }
.rule-actions { display: flex; gap: 8px; align-items: center; }
.rule-activate-btn {
  font-family: var(--ff-mono);
  font-size: 9px;
  font-weight: 700;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  padding: 5px 14px;
  color: var(--purple);
  border: 1px solid rgba(155,112,232,.3);
  background: transparent;
  cursor: pointer;
  transition: all 0.15s;
}
.rule-activate-btn:hover { background: rgba(155,112,232,.1); border-color: var(--purple); }
.rule-activate-btn:disabled { opacity: 0.35; cursor: default; }
.rule-activated-badge {
  font-family: var(--ff-mono);
  font-size: 9px;
  font-weight: 700;
  letter-spacing: 0.1em;
  text-transform: uppercase;
  padding: 5px 14px;
  color: var(--ch);
  border: 1px solid rgba(197,232,35,.3);
}

</style>
</head>
<body>

<header>
  <div class="masthead">
    Foundry<div class="masthead-pip"></div>
  </div>
  <div class="header-right">
    <div id="conn-status" class="live">
      <div class="conn-dot pulse"></div>
      <span id="conn-label">LIVE</span>
    </div>
    <time id="ts">—</time>
  </div>
</header>

<main>

  <!-- ── SIDEBAR ── -->
  <aside>

    <section class="now-section">
      <div class="now-top">
        <span class="eyebrow">Right Now</span>
        <span class="now-status ns-idle" id="now-pill">Idle</span>
      </div>
      <div id="now-body">
        <div class="idle-msg">Factory is quiet.</div>
        <div class="idle-sub" id="idle-sub">Connecting…</div>
      </div>
    </section>

    <div class="stats-section">
      <div class="stat">
        <div class="stat-n amb" id="stat-ideas">—</div>
        <div class="stat-lbl">ideas</div>
      </div>
      <div class="stat">
        <div class="stat-n ch" id="stat-built">—</div>
        <div class="stat-lbl">built</div>
      </div>
      <div class="stat">
        <div class="stat-n dim" id="stat-live">—</div>
        <div class="stat-lbl">live</div>
      </div>
    </div>

    <section class="projects-section">
      <div class="section-head">
        <span class="eyebrow">Projects</span>
      </div>
      <div class="proj-list" id="projects">
        <div style="color:var(--text3);font-size:13px;font-style:italic;padding:4px 0">Loading…</div>
      </div>
    </section>

    <div style="flex:1"></div>

    <div class="alerts-strip" id="alerts-section" style="display:none">
      <div class="alerts-hd">Needs Attention</div>
      <div id="alerts"></div>
    </div>

  </aside>

  <!-- ── RIGHT ── -->
  <div class="right">

    <nav class="tab-bar">
      <button class="tab active" id="tab-activity" onclick="setTab('activity')">Activity</button>
      <button class="tab" id="tab-spec"     onclick="setTab('spec')">Spec Log</button>
      <button class="tab" id="tab-build"    onclick="setTab('build')">Build Log</button>
      <button class="tab" id="tab-evolver"  onclick="setTab('evolver')">Evolver</button>
      <button class="tab" id="tab-history"  onclick="setTab('history')">History</button>
      <button class="tab" id="tab-rules"    onclick="setTab('rules')">Rules</button>
      <div class="tab-spacer"></div>
      <span class="tab-count" id="feed-count"></span>
    </nav>

    <div id="feed-panel"    class="panel"></div>
    <div id="raw-panel"     class="panel" style="display:none"></div>
    <div id="history-panel" class="panel" style="display:none"></div>
    <div id="rules-panel"   class="panel" style="display:none"></div>

  </div>

</main>

<script>
// ── State ─────────────────────────────────────────────────────────────────────
let currentTab = 'activity';
let latestData = null;
let autoScroll = true;
const eventTimestamps = {}; // msg → 'HH:MM' (first-seen)

const feedPanel    = document.getElementById('feed-panel');
const rawPanel     = document.getElementById('raw-panel');
const historyPanel = document.getElementById('history-panel');
const rulesPanel   = document.getElementById('rules-panel');

[feedPanel, rawPanel, historyPanel, rulesPanel].forEach(el => {
  el.addEventListener('scroll', () => {
    autoScroll = el.scrollHeight - el.scrollTop - el.clientHeight < 40;
  });
});

// ── Tab switching ──────────────────────────────────────────────────────────────
function setTab(t) {
  currentTab = t;
  document.querySelectorAll('.tab').forEach(el => el.classList.remove('active'));
  document.getElementById('tab-' + t).classList.add('active');

  feedPanel.style.display    = t === 'activity' ? '' : 'none';
  rawPanel.style.display     = ['spec','build','evolver'].includes(t) ? '' : 'none';
  historyPanel.style.display = t === 'history' ? '' : 'none';
  rulesPanel.style.display   = t === 'rules' ? '' : 'none';

  if (t === 'history') {
    loadHistory();
  } else if (t === 'rules') {
    loadRules();
  } else if (latestData) {
    t === 'activity' ? renderFeed(latestData) : renderRaw(latestData, t);
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────────
function esc(s) {
  return String(s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
}
function nowHHMM() {
  return new Date().toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' });
}

const BUILD_AGENTS = [
  { id:'planner',   label:'Plan',     verb:'Planning product architecture'   },
  { id:'builder',   label:'Build',    verb:'Writing the full codebase'       },
  { id:'qa',        label:'QA',       verb:'Reviewing & fixing code'         },
  { id:'designer',  label:'Design',   verb:'Polishing the UI'                },
  { id:'optimizer', label:'Optimise', verb:'Tuning performance'              },
];
const SPEC_STAGES = [
  { id:'ideating',   label:'Generating' },
  { id:'critiquing', label:'Critiquing' },
  { id:'refining',   label:'Refining'   },
  { id:'validating', label:'Validating' },
];

function badgeCls(status) {
  return {built:'b-built',deployed:'b-live',live:'b-live',queued:'b-queued',building:'b-building',
          needs_review:'b-review',needs_spec_revision:'b-review'}[status] || 'b-default';
}
function badgeTxt(status) {
  return {built:'Built',deployed:'Live ↗',live:'Live ↗',queued:'Queued',building:'Building',
          needs_review:'Review',needs_spec_revision:'Spec'}[status] || status;
}

// ── Render: Now card ───────────────────────────────────────────────────────────
function renderNow(d) {
  const body = document.getElementById('now-body');
  const pill = document.getElementById('now-pill');

  if (d.buildRunning && d.buildState.projectId) {
    const b = d.buildState;
    const a = BUILD_AGENTS.find(ag => ag.id === b.currentAgent) || {};
    pill.textContent = 'Building';
    pill.className   = 'now-status ns-building';

    const stepsHtml = BUILD_AGENTS.map((ag, i) => {
      const done   = b.completedAgents.includes(ag.id);
      const active = b.currentAgent === ag.id;
      const cls    = done ? 'done' : active ? 'active' : 'pending';
      const lCls   = done ? 'done' : active ? 'active' : '';
      const conn   = i < BUILD_AGENTS.length - 1
        ? \`<div class="pip-connector \${done?'done':''}"></div>\` : '';
      return \`<div class="pip-step">
        <div class="pip-node \${cls}"><span>\${i+1}</span></div>
        <div class="pip-lbl \${lCls}">\${esc(ag.label)}</div>
      </div>\${conn}\`;
    }).join('');

    body.innerHTML = \`
      <div class="build-name">\${esc(b.projectName || b.projectId)}</div>
      <div class="build-verb">\${a.verb ? esc(a.verb) : 'Starting up…'}</div>
      <div class="pipeline">\${stepsHtml}</div>
    \`;

  } else if (d.specRunning && d.specState.stage) {
    const s = d.specState;
    const si = SPEC_STAGES.findIndex(st => st.id === s.stage);
    pill.textContent = 'Generating';
    pill.className   = 'now-status ns-spec';

    const stagesHtml = SPEC_STAGES.map((st, i) => {
      const done   = i < si;
      const active = i === si;
      const cls    = done ? 'done' : active ? 'active' : '';
      return \`<div class="spec-pill \${cls}">\${esc(st.label)}</div>\`;
    }).join('');

    body.innerHTML = \`
      <div class="spec-headline">Generating ideas</div>
      <div class="spec-meta">Attempt \${s.attempt||'?'} · \${s.queued||0}/\${s.target||2} approved</div>
      <div class="spec-stages">\${stagesHtml}</div>
    \`;

  } else {
    pill.textContent = 'Idle';
    pill.className   = 'now-status ns-idle';
    const queued = d.projects.filter(p=>p.status==='queued').length;
    const built  = d.projects.filter(p=>p.status==='built').length;
    const subText = queued  ? \`\${queued} project\${queued>1?'s':''} ready to build\`
                  : built   ? \`\${built} product\${built>1?'s':''} awaiting approval\`
                  : 'Nothing queued';
    body.innerHTML = \`
      <div class="idle-msg">Factory is quiet.</div>
      <div class="idle-sub">\${esc(subText)}</div>
    \`;
  }
}

// ── Render: Stats ──────────────────────────────────────────────────────────────
function renderStats(d) {
  document.getElementById('stat-ideas').textContent = d.todayStats.specsRun || 0;
  document.getElementById('stat-built').textContent = d.todayStats.totalBuilt || 0;
  document.getElementById('stat-live').textContent  = d.todayStats.totalDeployed || 0;
}

// ── Render: Projects ───────────────────────────────────────────────────────────
function renderProjects(d) {
  const el = document.getElementById('projects');
  if (!d.projects.length) {
    el.innerHTML = '<div style="color:var(--text3);font-size:13px;font-style:italic;padding:4px 0">No projects yet</div>';
    return;
  }

  const bState = d.buildState;
  el.innerHTML = [...d.projects].reverse().map(p => {
    const isActive = p.id === bState.projectId;
    const isLive   = p.status === 'live' || p.status === 'deployed';
    let rowCls = 'proj-row';
    if (isActive) rowCls += ' is-active';
    else if (isLive) rowCls += ' is-live';

    const nameHtml = (isLive && p.live_url)
      ? \`<a href="\${esc(p.live_url)}" target="_blank" rel="noopener">\${esc(p.displayName || p.id)}</a>\`
      : esc(p.displayName || p.id);

    const deployBtn = p.status === 'built'
      ? \`<button class="deploy-btn" onclick="approveProject(this, '\${esc(p.id)}')">Deploy →</button>\`
      : '';

    let extra = '';
    if (p.status === 'building' && isActive) {
      const segs = ['planner','builder','qa','designer','optimizer'].map(id => {
        const done   = bState.completedAgents.includes(id);
        const active = bState.currentAgent === id;
        return \`<div class="mini-seg \${done?'done':active?'active':''}"></div>\`;
      }).join('');
      extra = \`<div class="mini-bar">\${segs}</div>\`;
    }

    return \`<div class="\${rowCls}">
      <div class="proj-row-top">
        <div class="proj-row-name">\${nameHtml}</div>
        \${deployBtn}
        <span class="badge \${badgeCls(p.status)}">\${esc(badgeTxt(p.status))}</span>
      </div>
      \${p.displayTagline ? \`<div class="proj-row-tag">\${esc(p.displayTagline.slice(0,60))}</div>\` : ''}
      \${extra}
    </div>\`;
  }).join('');
}

// ── Deploy ─────────────────────────────────────────────────────────────────────
function approveProject(btn, projectId) {
  btn.disabled = true;
  btn.textContent = 'Deploying…';
  fetch('/api/approve/' + projectId, { method: 'POST' })
    .then(r => {
      if (r.status === 202) {
        btn.textContent = 'Queued ✓';
        btn.style.color = 'var(--ch)';
        btn.style.borderColor = 'rgba(197,232,35,.4)';
      } else {
        throw new Error('non-202');
      }
    })
    .catch(() => {
      btn.textContent = 'Failed ✕';
      btn.style.color = 'var(--red)';
      setTimeout(() => {
        btn.disabled = false;
        btn.textContent = 'Deploy →';
        btn.style.color = '';
        btn.style.borderColor = '';
      }, 2500);
    });
}

// ── Render: Activity Feed ──────────────────────────────────────────────────────
const evIcons  = { ok:'✓', warn:'⚠', fail:'✕', agent:'●', info:'·' };
const srcLabel = { spec:'Spec', build:'Build', evolver:'Evolve' };

function recordEventTimes(events) {
  const t = nowHHMM();
  for (const e of events) {
    if (!eventTimestamps[e.msg]) eventTimestamps[e.msg] = t;
  }
}

function renderFeed(d) {
  recordEventTimes(d.activity);
  const isRunning = d.buildRunning || d.specRunning;
  document.getElementById('feed-count').textContent =
    d.activity.length ? d.activity.length + ' events' : '';

  if (!d.activity.length) {
    feedPanel.innerHTML = \`<div class="feed-empty">
      <div class="feed-empty-icon">📋</div>
      <div>Activity will appear here once the factory runs</div>
    </div>\`;
    return;
  }

  const wasBottom = feedPanel.scrollHeight - feedPanel.scrollTop - feedPanel.clientHeight < 40;
  feedPanel.innerHTML = d.activity.map((e, i) => {
    const isLast     = i === d.activity.length - 1 && isRunning;
    const ts         = eventTimestamps[e.msg] || '';
    const detailHtml = e.detail ? \`<span class="ev-detail">\${esc(e.detail)}</span>\` : '<span></span>';
    return \`<div class="ev-row \${e.type}">
      <span class="ev-time">\${esc(ts)}</span>
      <span class="ev-icon">\${evIcons[e.type]||'·'}</span>
      <span class="ev-msg">\${esc(e.msg)}\${isLast ? '<span class="cursor"></span>' : ''}</span>
      \${detailHtml}
      <span class="ev-src \${e.source}">\${esc(srcLabel[e.source]||e.source)}</span>
    </div>\`;
  }).join('');

  if (wasBottom || autoScroll) feedPanel.scrollTop = feedPanel.scrollHeight;
}

// ── Render: Raw Log ────────────────────────────────────────────────────────────
function classifyRaw(l) {
  if (l.match(/\[  ✓  \]|complete|passed/i))   return 'ok';
  if (l.match(/\[ ⚠️  \]|WARN/i))               return 'warn';
  if (l.match(/\[  ✗  \]|Error|FAIL|failed/i)) return 'fail';
  if (l.match(/\[spec\]|\[factory\]|\[orchestrate\]|\[agent\]/)) return 'info';
  if (l.match(/^[═─ ]+$/))                       return 'dim';
  return '';
}

function renderRaw(d, tab) {
  const lines   = tab==='spec' ? d.specLogLines : tab==='build' ? d.buildLogLines : d.evolverLogLines;
  const running = d.buildRunning || d.specRunning;
  if (!lines || !lines.length) {
    rawPanel.innerHTML = '<div style="color:var(--text3);padding:24px;font-size:11px">No output yet.</div>';
    return;
  }
  const wasBottom = rawPanel.scrollHeight - rawPanel.scrollTop - rawPanel.clientHeight < 40;
  rawPanel.innerHTML = lines.map((l, i) => {
    const isLast = i === lines.length-1 && running;
    return \`<div class="ll \${classifyRaw(l)}">\${esc(l)}\${isLast?'<span class="cursor"></span>':''}</div>\`;
  }).join('');
  if (wasBottom || autoScroll) rawPanel.scrollTop = rawPanel.scrollHeight;
}

// ── History ────────────────────────────────────────────────────────────────────
const HISTORY_EVENT_MAP = {
  spec_started:           { icon: '💡', label: 'Generating idea',       cls: 'hev-blue'   },
  spec_written:           { icon: '📝', label: 'Spec written',           cls: 'hev-blue'   },
  spec_killed:            { icon: '✕',  label: 'Idea killed',            cls: 'hev-red'    },
  spec_rewrite:           { icon: '✏',  label: 'Needs improvement',      cls: 'hev-amber'  },
  spec_approved:          { icon: '✓',  label: 'Idea approved',          cls: 'hev-green'  },
  spec_queued:            { icon: '→',  label: 'Queued for build',       cls: 'hev-green'  },
  spec_needs_review:      { icon: '⚠',  label: 'Needs review',           cls: 'hev-amber'  },
  spec_pipeline_complete: { icon: '✓',  label: 'Spec pipeline done',     cls: 'hev-green'  },
  build_started:          { icon: '⬡',  label: 'Build started',          cls: 'hev-blue'   },
  agent_complete:         { icon: '✓',  label: 'Agent done',             cls: 'hev-green'  },
  agent_failed:           { icon: '✕',  label: 'Agent failed',           cls: 'hev-red'    },
  build_complete:         { icon: '✓',  label: 'Build complete',         cls: 'hev-green'  },
  build_paused:           { icon: '‖',  label: 'Build paused',           cls: 'hev-amber'  },
  deployed:               { icon: '↗',  label: 'Live!',                  cls: 'hev-deploy' },
  deploy_failed:          { icon: '✕',  label: 'Deploy failed',          cls: 'hev-red'    },
  evolver_complete:       { icon: '◈',  label: 'Evolver ran',            cls: 'hev-purple' },
  rule_proposed:          { icon: '✦',  label: 'Rule proposed',          cls: 'hev-purple' },
};

function fmtHistoryTime(tsStr) {
  try {
    const d = new Date(tsStr);
    return d.toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit' });
  } catch { return ''; }
}

function fmtHistoryDate(tsStr) {
  try {
    const d = new Date(tsStr);
    const today = new Date();
    const yesterday = new Date(today); yesterday.setDate(yesterday.getDate()-1);
    const ds = d.toDateString();
    if (ds === today.toDateString()) return 'Today';
    if (ds === yesterday.toDateString()) return 'Yesterday';
    return d.toLocaleDateString('en-GB', { weekday:'long', month:'short', day:'numeric' });
  } catch { return tsStr; }
}

function getHistoryDay(tsStr) {
  try { return new Date(tsStr).toDateString(); } catch { return tsStr; }
}

function buildHistoryEventMsg(ev) {
  const map = HISTORY_EVENT_MAP[ev.type] || { icon: '·', label: ev.type, cls: '' };
  let label = map.label;
  if (ev.type === 'agent_complete' && ev.agent) label = esc(ev.agent) + ' done';
  if (ev.type === 'agent_failed'   && ev.agent) label = esc(ev.agent) + ' failed';
  if (ev.type === 'spec_killed'    && ev.score) label = 'Idea killed';
  if (ev.type === 'evolver_complete' && ev.proposals_count != null)
    label = 'Evolver ran · ' + ev.proposals_count + ' proposals';
  return { icon: map.icon, label, cls: map.cls };
}

function buildHistoryDetail(ev) {
  if (ev.type === 'deployed' && ev.url) {
    return \`<a href="\${esc(ev.url)}" target="_blank" rel="noopener">\${esc(ev.url.replace('https://',''))}</a>\`;
  }
  if (ev.type === 'spec_killed' && ev.score) return esc(ev.score) + '/50';
  if (ev.type === 'agent_complete' && ev.duration) {
    const n = parseInt(ev.duration);
    if (!isNaN(n)) return (n < 60 ? n + 's' : Math.round(n/60) + 'm');
  }
  return '';
}

function loadHistory() {
  historyPanel.innerHTML = '<div style="color:var(--text3);padding:24px;font-size:12px">Loading…</div>';
  fetch('/api/history')
    .then(r => r.json())
    .then(events => renderHistory(events))
    .catch(() => {
      historyPanel.innerHTML = '<div style="color:var(--text3);padding:24px;font-size:12px">Could not load history.</div>';
    });
}

function renderHistory(events) {
  document.getElementById('feed-count').textContent = events.length ? events.length + ' events' : '';

  if (!events.length) {
    historyPanel.innerHTML = \`<div class="feed-empty">
      <div class="feed-empty-icon" style="opacity:.2">✦</div>
      <div>No history yet — builds up as the factory runs.</div>
    </div>\`;
    return;
  }

  let html = '';
  let lastDay = null;

  for (const ev of events) {
    const day = getHistoryDay(ev.ts);
    if (day !== lastDay) {
      html += \`<div class="hist-date-sep">\${esc(fmtHistoryDate(ev.ts))}</div>\`;
      lastDay = day;
    }
    const { icon, label, cls } = buildHistoryEventMsg(ev);
    const detail      = buildHistoryDetail(ev);
    const projectName = ev.project_name || ev.project_id || '';
    html += \`<div class="hev \${cls}">
      <span class="hev-time">\${esc(fmtHistoryTime(ev.ts))}</span>
      <span class="hev-icon">\${icon}</span>
      <span class="hev-msg">\${label}</span>
      <span class="hev-project">\${esc(projectName)}</span>
      <span class="hev-detail">\${detail}</span>
    </div>\`;
  }

  historyPanel.innerHTML = html;
  historyPanel.scrollTop = historyPanel.scrollHeight;
}

// ── Rules ──────────────────────────────────────────────────────────────────────
function loadRules() {
  rulesPanel.innerHTML = '<div style="color:var(--text3);padding:24px;font-size:12px">Loading…</div>';
  fetch('/api/rules')
    .then(r => r.json())
    .then(proposals => renderRules(proposals))
    .catch(() => {
      rulesPanel.innerHTML = '<div style="color:var(--text3);padding:24px;font-size:12px">Could not load rules.</div>';
    });
}

function renderRules(proposals) {
  document.getElementById('feed-count').textContent = proposals.length ? proposals.length + ' proposals' : '';

  if (!proposals.length) {
    rulesPanel.innerHTML = \`<div class="feed-empty">
      <div class="feed-empty-icon" style="opacity:.2">✦</div>
      <div>No proposals yet — Evolver writes these nightly.</div>
    </div>\`;
    return;
  }

  rulesPanel.innerHTML = proposals.map(p => {
    const confCls = { high:'high', medium:'medium', low:'low' }[p.confidence?.toLowerCase()] || 'low';
    const isActivated = p.status?.toLowerCase() === 'activated';

    const actionHtml = isActivated
      ? \`<span class="rule-activated-badge">Activated ✓</span>\`
      : \`<button class="rule-activate-btn" onclick="activateRule(this, \${JSON.stringify(esc(p.ruleId))}, \${JSON.stringify(esc(p.appendToPrompt))}, \${JSON.stringify(esc(p.agent))}, \${JSON.stringify(esc(p.confidence))}, \${JSON.stringify(esc(p.sourceFile))})">Activate</button>\`;

    return \`<div class="rule-card">
      <div class="rule-top">
        <div class="rule-name">\${esc(p.ruleName)}</div>
        \${p.agent ? \`<span class="rule-agent-tag">\${esc(p.agent)}</span>\` : ''}
        <span class="rule-conf \${confCls}">\${esc(p.confidence || 'unknown')}</span>
      </div>
      \${p.pattern ? \`<div class="rule-pattern">\${esc(p.pattern)}</div>\` : ''}
      <div class="rule-actions">\${actionHtml}</div>
    </div>\`;
  }).join('');
}

function activateRule(btn, ruleId, appendToPrompt, agent, confidence, sourceFile) {
  btn.disabled = true;
  btn.textContent = 'Activating…';
  fetch('/api/rules/activate', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ ruleId, appendToPrompt, agent, confidence, sourceFile }),
  })
    .then(r => r.json())
    .then(data => {
      if (data.ok) {
        btn.outerHTML = '<span class="rule-activated-badge">Activated ✓</span>';
      } else {
        throw new Error('not ok');
      }
    })
    .catch(() => {
      btn.textContent = 'Failed ✕';
      setTimeout(() => {
        btn.disabled = false;
        btn.textContent = 'Activate';
      }, 2500);
    });
}

// ── Main render ────────────────────────────────────────────────────────────────
function render(d) {
  latestData = d;
  const t = new Date(d.ts);
  document.getElementById('ts').textContent =
    t.toLocaleTimeString('en-GB', { hour:'2-digit', minute:'2-digit', second:'2-digit' });

  renderNow(d);
  renderStats(d);
  renderProjects(d);

  if (currentTab === 'activity') {
    renderFeed(d);
  } else if (['spec','build','evolver'].includes(currentTab)) {
    renderRaw(d, currentTab);
  }

  const aSection = document.getElementById('alerts-section');
  if (d.alerts.length) {
    aSection.style.display = '';
    document.getElementById('alerts').innerHTML = d.alerts.map(a =>
      \`<div class="alert-line">\${esc(a)}</div>\`).join('');
  } else {
    aSection.style.display = 'none';
  }
}

// ── SSE ────────────────────────────────────────────────────────────────────────
let reconnDelay = 1000;
function connect() {
  const es = new EventSource('/events');
  es.onmessage = e => {
    reconnDelay = 1000;
    try { render(JSON.parse(e.data)); } catch {}
  };
  es.onerror = () => {
    const cs  = document.getElementById('conn-status');
    const dot = cs.querySelector('.conn-dot');
    document.getElementById('conn-label').textContent = 'RECONNECTING';
    cs.className = 'dead';
    dot.classList.remove('pulse');
    es.close();
    setTimeout(connect, reconnDelay);
    reconnDelay = Math.min(reconnDelay * 2, 10000);
  };
  es.onopen = () => {
    const cs  = document.getElementById('conn-status');
    const dot = cs.querySelector('.conn-dot');
    document.getElementById('conn-label').textContent = 'LIVE';
    cs.className = 'live';
    dot.classList.add('pulse');
  };
}
connect();
</script>
</body>
</html>`;

// ── HTTP Server ───────────────────────────────────────────────────────────────

const server = http.createServer((req, res) => {
  if (req.url === '/events') {
    res.writeHead(200, { 'Content-Type':'text/event-stream','Cache-Control':'no-cache','Connection':'keep-alive','Access-Control-Allow-Origin':'*' });
    try { res.write(`data: ${JSON.stringify(getStatus())}\n\n`); } catch {}
    clients.add(res);
    req.on('close', () => clients.delete(res));
    return;
  }

  if (req.url === '/api/projects') {
    res.writeHead(200, { 'Content-Type':'application/json' });
    res.end(JSON.stringify(readJSON(PROJECTS_JSON)||{}));
    return;
  }

  if (req.url === '/api/history') {
    const eventsFile = path.join(LOGS_DIR, 'events.jsonl');
    let events = [];
    try {
      events = fs.readFileSync(eventsFile, 'utf8')
        .split('\n').filter(Boolean)
        .slice(-200)
        .map(l => { try { return JSON.parse(l); } catch { return null; } })
        .filter(Boolean);
    } catch {}
    res.writeHead(200, { 'Content-Type':'application/json' });
    res.end(JSON.stringify(events));
    return;
  }

  if (req.url === '/api/rules') {
    const proposals = parseRuleProposals();
    res.writeHead(200, { 'Content-Type':'application/json' });
    res.end(JSON.stringify(proposals));
    return;
  }

  if (req.method === 'POST' && req.url === '/api/rules/activate') {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      try {
        const data = JSON.parse(body);
        const rulesPath = path.join(FOUNDRY_DIR, 'agents', 'rules.json');
        const rules = readJSON(rulesPath) || { version: 1, rules: [] };
        if (!rules.rules.find(r => r.id === data.ruleId)) {
          rules.rules.push({
            id: data.ruleId,
            agent: data.agent || 'ideator',
            active: true,
            added: new Date().toISOString().slice(0,10),
            source: 'operator',
            confidence: data.confidence || 'high',
            append_to_prompt: data.appendToPrompt,
          });
          fs.writeFileSync(rulesPath, JSON.stringify(rules, null, 2));
        }
        res.writeHead(200, { 'Content-Type':'application/json' });
        res.end(JSON.stringify({ ok: true }));
      } catch (err) {
        res.writeHead(400, { 'Content-Type':'application/json' });
        res.end(JSON.stringify({ ok: false, error: String(err) }));
      }
    });
    return;
  }

  if (req.method === 'POST' && req.url.startsWith('/api/approve/')) {
    const projectId = req.url.replace('/api/approve/', '').split('?')[0];
    const child = spawn('/bin/bash', [
      path.join(FOUNDRY_DIR, 'approve.sh'),
      '--yes',
      projectId
    ], {
      detached: true,
      stdio: 'ignore',
      env: { ...process.env, CLAUDECODE: undefined },
    });
    child.unref();
    res.writeHead(202, { 'Content-Type':'application/json' });
    res.end(JSON.stringify({ ok: true, message: `Deploying ${projectId}…` }));
    return;
  }

  res.writeHead(200, { 'Content-Type':'text/html; charset=utf-8' });
  res.end(HTML);
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`\n  Foundry Dashboard → http://localhost:${PORT}\n`);
});
server.on('error', err => {
  if (err.code === 'EADDRINUSE') { console.error(`  Port ${PORT} in use.`); process.exit(1); }
  throw err;
});
