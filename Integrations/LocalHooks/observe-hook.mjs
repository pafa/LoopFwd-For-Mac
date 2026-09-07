// LoopFwd's own read-only observer. No provider decisions or transcript storage.
import { execFileSync } from 'node:child_process';
import { createHash, randomUUID } from 'node:crypto';
import { promises as fs, constants, readFileSync, statSync, realpathSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const events = {
  mistral: new Set(['pre_tool', 'post_tool', 'post_agent']),
  gemini: new Set(['SessionStart', 'BeforeAgent', 'BeforeModel', 'AfterModel', 'BeforeTool', 'AfterTool', 'AfterAgent', 'Notification', 'SessionEnd']),
  qwen: new Set(['SessionStart', 'UserPromptSubmit', 'MessageDisplay', 'PreToolUse', 'PostToolUse', 'PostToolUseFailure', 'Notification', 'Stop', 'StopFailure', 'SessionEnd']),
  copilot: new Set(['userPromptSubmitted', 'preToolUse', 'postToolUse', 'agentStop', 'notification', 'sessionEnd']),
  cursor: new Set(['sessionStart', 'beforeSubmitPrompt', 'afterAgentThought', 'afterAgentResponse', 'preToolUse', 'postToolUse', 'postToolUseFailure', 'stop', 'sessionEnd']),
  workbuddy: new Set(['UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'PermissionRequest', 'Stop', 'FinalStop', 'StopFailure']),
  kimi: new Set(['SessionStart', 'SessionHeartbeat', 'SessionEnd']),
};
const bounded = (value, max) => typeof value === 'string' ? value.slice(0, max) : undefined;
const identity = value => typeof value === 'string' && /^[a-zA-Z0-9_.:-]{1,128}$/.test(value) ? value : undefined;

export function mistralDataRoot(environment = process.env, workingDirectory = process.cwd(), home = os.homedir()) {
  let root = environment.VIBE_HOME || path.join(home, '.vibe');
  if (typeof root !== 'string' || root.includes('\0') || Buffer.byteLength(root) > 4096) throw new Error('Invalid Vibe data root');
  if (root === '~' || root.startsWith('~/')) root = home + root.slice(1);
  else if (root.startsWith('~')) throw new Error('Unsupported Vibe data root');
  root = path.resolve(workingDirectory, root);
  if (Buffer.byteLength(root) > 4096) throw new Error('Vibe data root exceeds budget');
  return root;
}

export function normalize(provider, input, eventOverride, owner, now = Date.now(), runtimeSessionID, dataRoot) {
  const eventName = eventOverride ?? input.hook_event_name ?? input.hookEventName;
  const sessionID = identity(provider === 'cursor' ? input.conversation_id : input.session_id ?? input.sessionId);
  if (!events[provider]?.has(eventName) || !sessionID) throw new Error('Unsupported event or missing session identity');
  if (provider === 'kimi') {
    // Kimi v2 lifecycle hooks identify a live session, not an active turn.
    // The selected data root is supplied by our installed command, not stdin.
    if (input.client_type !== 'kimi_code_cli' || input.agent_id || input.parent_session_id
      || !path.isAbsolute(dataRoot ?? '') || dataRoot.includes('\0') || Buffer.byteLength(dataRoot) > 4096
      || !path.isAbsolute(input.cwd ?? '') || input.cwd.includes('\0') || Buffer.byteLength(input.cwd) > 4096) {
      throw new Error('Unsupported Kimi lifecycle source');
    }
    return { schemaVersion: 1, provider, sessionID, eventName, observedAt: now,
      ownerPID: owner?.pid ?? null, ownerStartedAt: owner?.startedAt ?? null,
      providerDataRoot: path.resolve(dataRoot), cwd: path.resolve(input.cwd), clientType: input.client_type };
  }
  const timestamp = typeof input.timestamp === 'string' ? Date.parse(input.timestamp) : NaN;
  const candidates = Array.isArray(input.llm_response?.candidates) ? input.llm_response.candidates.slice(0, 16) : [];
  const hasModelContent = provider === 'cursor'
    ? ['afterAgentThought', 'afterAgentResponse'].includes(eventName) && typeof input.text === 'string' && input.text.trim().length > 0
    : provider === 'qwen'
    ? typeof input.displayed_text === 'string' && input.displayed_text.trim().length > 0
    : (typeof input.llm_response?.text === 'string' && input.llm_response.text.trim().length > 0)
      || candidates.some(candidate => Array.isArray(candidate.content?.parts) && candidate.content.parts.slice(0, 64)
        .some(part => typeof part === 'string' && part.trim().length > 0));
  return {
    schemaVersion: 1, provider, sessionID, eventName, observedAt: now,
    sourceAt: !['cursor', 'workbuddy'].includes(provider) && Number.isFinite(timestamp) && timestamp > 0 && timestamp <= now + 5000 ? timestamp : undefined,
    providerVersion: provider === 'cursor' ? bounded(input.cursor_version, 64) : provider === 'workbuddy' ? bounded(owner?.providerVersion, 64) : undefined,
    generationID: ['cursor', 'workbuddy'].includes(provider) ? identity(input.generation_id) : undefined,
    loopCount: provider === 'cursor' && Number.isSafeInteger(input.loop_count) && input.loop_count >= 0 ? input.loop_count : undefined,
    stopReason: provider === 'workbuddy' && eventName === 'FinalStop'
      ? (['completed', 'cancelled', 'failed', 'interrupted'].includes(input.final_stop_reason) ? input.final_stop_reason : undefined)
      : provider === 'cursor' && eventName === 'stop' && ['completed', 'aborted', 'error'].includes(input.status) ? input.status : undefined,
    runtimeSessionID: provider === 'workbuddy' ? identity(runtimeSessionID) : undefined,
    ownerAppPath: provider === 'workbuddy' ? bounded(owner?.appPath, 4096) : undefined,
    ownerHostPID: provider === 'workbuddy' ? owner?.hostPID : undefined,
    ownerHostStartedAt: provider === 'workbuddy' ? owner?.hostStartedAt : undefined,
    sourceType: bounded(input.source_type, 64),
    messageID: identity(input.message_id),
    isFinal: typeof input.is_final === 'boolean' ? input.is_final : undefined,
    hasModelContent,
    agentID: identity(input.agent_id),
    hasSubmittedPrompt: typeof input.submitted_prompt === 'string' && input.submitted_prompt.trim().length > 0,
    isInterrupt: typeof input.is_interrupt === 'boolean' ? input.is_interrupt : undefined,
    failureCode: ['loop_detected', 'rate_limit', 'authentication_failed', 'billing_error', 'invalid_request', 'server_error', 'max_output_tokens', 'unknown'].includes(input.error) ? input.error : undefined,
    ownerPID: owner?.pid ?? null, ownerStartedAt: owner?.startedAt ?? null,
    // Comes from the observer child's inherited environment, never Hook input.
    // Vibe's setproctitle hides this environment from macOS KERN_PROCARGS2.
    providerDataRoot: provider === 'mistral' ? dataRoot : undefined,
    transcriptPath: bounded(input.transcript_path, 4096),
    cwd: bounded(input.cwd ?? input.workingDirectory ?? (provider === 'cursor' && input.workspace_roots?.length === 1 ? input.workspace_roots[0] : undefined), 4096),
    parentSessionID: identity(input.parent_session_id ?? (provider === 'cursor' ? input.parent_conversation_id : undefined)),
    toolName: bounded(input.tool_name ?? input.toolName, 128),
    toolID: identity(input.tool_call_id ?? input.tool_use_id ?? input.toolCallId),
    notificationType: bounded(input.notification_type ?? input.notificationType, 128),
    toolStatus: ['success', 'failure', 'cancelled'].includes(input.tool_status) ? input.tool_status : undefined,
  };
}

// Inspect only installed application metadata; never load the CLI entrypoint or
// settings loader. WorkBuddy's outer package version is a placeholder (0.0.0).
export function workBuddyBundle(appPath) {
  const options = { encoding: 'utf8', timeout: 180, maxBuffer: 32768, stdio: ['ignore', 'pipe', 'ignore'] };
  const info = JSON.parse(execFileSync('/usr/bin/plutil', ['-convert', 'json', '-o', '-', path.join(appPath, 'Contents/Info.plist')], options));
  if (info.CFBundleIdentifier !== 'com.tencent.workbuddy.mac') return undefined;
  const packagePath = path.join(appPath, 'Contents/Resources/app.asar.unpacked/cli/package.json');
  if (statSync(packagePath).size > 128 * 1024) return undefined;
  const pkg = JSON.parse(readFileSync(packagePath, 'utf8'));
  const version = pkg.publishConfig?.customPackage?.version ?? pkg.version;
  if (typeof version !== 'string' || !/^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$/.test(version)) return undefined;
  return { providerVersion: version };
}

// ps does not quote paths containing spaces. Recognize only a launched program
// or its first interpreter argument; never search a prompt for an app path.
export function workBuddyCLIApp(command) {
  const script = '(\/[^\\n]*?\\.app)/Contents/Resources/app\\.asar\\.unpacked/cli/(?:bin/codebuddy|dist/codebuddy(?:-headless)?\\.js)(?= |$)';
  const valid = match => match && !/\s+[\/-]/.test(match[1]) ? match[1] : undefined;
  let match = new RegExp('^' + script).exec(command);
  if (valid(match)) return valid(match);
  const launcher = '(?:\\S*/(?:node|nodejs)|/[^\\n]*?\\.app/Contents/(?:MacOS/WorkBuddy|Frameworks/[^\\n]*?\\.app/Contents/MacOS/WorkBuddy Helper(?: \\([A-Za-z ]+\\))?)) +';
  match = new RegExp('^(' + launcher + ')' + script).exec(command);
  if (!match || /\s+[\/-]/.test(match[1].trim())) return undefined;
  match = [match[0], match[2]];
  return valid(match);
}

export function findWorkBuddyOwner(parentPID = process.ppid, read = readProcess, validate = workBuddyBundle) {
  const seen = new Set(), deadline = Date.now() + 600;
  let candidate;
  for (let pid = parentPID, depth = 0; pid > 1 && depth < 8 && !seen.has(pid) && Date.now() < deadline; depth++) {
    seen.add(pid);
    let item;
    try { item = read(pid); } catch { return undefined; }
    if (!item) return undefined;
    if (candidate && item.startedAt && (
      item.command.startsWith(candidate.appPath + '/Contents/MacOS/') ||
      item.command.startsWith(candidate.appPath + '/Contents/Frameworks/')
    )) {
      // Recheck both births before binding a shared host to any event.
      try {
        const current = read(candidate.pid), host = read(pid);
        if (current.startedAt !== candidate.startedAt || host.startedAt !== item.startedAt
          || workBuddyCLIApp(current.command) !== candidate.appPath || host.command !== item.command) return undefined;
      } catch { return undefined; }
      return { ...candidate, hostPID: pid, hostStartedAt: item.startedAt };
    }
    if (!candidate) {
      const appPath = workBuddyCLIApp(item.command);
      if (appPath && item.startedAt) {
        let metadata;
        try { metadata = validate(appPath); } catch { return undefined; }
        if (!metadata) return undefined;
        candidate = { pid, startedAt: item.startedAt, appPath, providerVersion: metadata.providerVersion };
      }
    }
    pid = item.parent;
  }
  // Detached prewarm/serve processes without a provable host remain unbound.
  return undefined;
}

function readProcess(pid) {
  const text = execFileSync('/bin/ps', ['-p', String(pid), '-o', 'ppid=', '-o', 'lstart=', '-o', 'args='], {
    encoding: 'utf8', timeout: 180, maxBuffer: 16384, env: { ...process.env, LC_ALL: 'C' },
    stdio: ['ignore', 'pipe', 'ignore'],
  }).trim();
  const match = /^(\d+)\s+(\w{3}\s+\w{3}\s+\d+\s+\d{2}:\d{2}:\d{2}\s+\d{4})\s+([\s\S]+)$/.exec(text);
  if (!match) throw new Error('Process identity unavailable');
  return { pid, parent: Number(match[1]), startedAt: match[2], command: match[3] };
}

export function findOwner(provider, parentPID = process.ppid, read = readProcess) {
  if (provider === 'workbuddy') return findWorkBuddyOwner(parentPID, read);
  const executables = { mistral: 'vibe', gemini: 'gemini', qwen: 'qwen', copilot: 'copilot', cursor: 'cursor-agent', kimi: 'kimi' };
  const executable = executables[provider];
  if (!executable) return undefined;
  const pattern = new RegExp(`^(?!-)(?:[^ ]*/)?${executable}(?: |$)|^(?:[^ ]*/)?(?:python[0-9.]*|node) +(?!-)(?:[^ ]*/)?${executable}(?: |$)`);
  const officialNodeEntry = provider === 'gemini'
    ? /^(?:[^ ]*\/)?node +(?:(?:--expose-gc|--enable-source-maps|--no-warnings|--max-old-space-size=[1-9][0-9]*) +)*(?!-)[^ ]*\/@google\/gemini-cli\/bundle\/gemini\.js(?: |$)/
    : provider === 'qwen' ? /^(?:[^ ]*\/)?node +(?:(?:--expose-gc|--enable-source-maps|--no-warnings|--max-old-space-size=[1-9][0-9]*) +)*(?!-)[^ ]*\/@qwen-code\/qwen-code\/(?:cli-entry|cli)\.js(?: |$)/ : undefined;
  const seen = new Set();
  const deadline = Date.now() + 600;
  for (let pid = parentPID, depth = 0; pid > 1 && depth < 8 && !seen.has(pid) && Date.now() < deadline; depth++) {
    seen.add(pid);
    let item;
    try { item = read(pid); } catch { return undefined; }
    // Vibe 2.25.0 calls setproctitle before argument parsing. Match only its
    // exact official title, not a substring or a later command argument.
    const officialVibeTitle = provider === 'mistral' && item.command.trim() === 'Vibe CLI';
    const officialKimiTitle = provider === 'kimi' && item.command.trim() === 'kimi-code';
    if ((officialVibeTitle || officialKimiTitle || pattern.test(item.command) || officialNodeEntry?.test(item.command)) && item.startedAt) return { pid, startedAt: item.startedAt };
    pid = item.parent;
  }
  return undefined;
}

const digest = x => createHash('sha256').update(x).digest('hex');
const scopeName = event => `${event.provider}-${event.ownerPID ?? 'unbound'}-${digest((event.ownerStartedAt ?? '').trim().split(/\s+/).join(' '))}-${digest(event.sessionID ?? '')}`;
const scopePattern = /^(mistral|gemini|qwen|copilot|cursor|workbuddy|kimi)-(unbound|[1-9]\d{0,9})-[a-f0-9]{64}-[a-f0-9]{64}$/;
const eventPattern = /^\d{13}-[a-f0-9-]{36}\.json$/;
const privateItem = (stat, mode) => !stat.isSymbolicLink() && stat.uid === process.getuid() && (stat.mode & 0o777) === mode;

async function limitedNames(directory, maximum = 256, partial = false) {
  const names=[];
  for await (const item of await fs.opendir(directory)) {
    if(names.length === maximum) return partial ? names.sort() : null;
    names.push(item.name);
  }
  return names.sort();
}

export function ownerHasExited(pid) {
  if(!Number.isInteger(pid) || pid <= 1 || pid > 2147483647) return false;
  try {process.kill(pid,0);return false;} catch(error) {return error.code === 'ESRCH';}
}

// Capacity recovery, not an archive or LRU eviction. Unknown or live owners stay.
// Quarantine keeps interrupted or concurrently changed records recoverable.
export async function reclaimExpiredScopes(root, {now=Date.now(), probe=ownerHasExited, afterQuarantine=async()=>{}}={}) {
  const deadline=performance.now()+200, cutoff=now-24*60*60*1000;
  const gc=path.join(root,'.gc');
  const rootStat=await fs.lstat(root);
  if(!rootStat.isDirectory() || !privateItem(rootStat,0o700)) return 0;
  let moved=0;
  const expired=async(directory,scope,allowEmpty=false)=>{
    if(performance.now()>=deadline) return null;
    const match=scopePattern.exec(scope), pid=Number(match?.[2]);
    if(!match || !probe(pid)) return null;
    const stat=await fs.lstat(directory);
    if(!stat.isDirectory() || !privateItem(stat,0o700) || stat.mtimeMs>=cutoff) return null;
    const names=await limitedNames(directory,64);
    if(!names || (!allowEmpty && names.length===0) || names.some(x=>!eventPattern.test(x))) return null;
    const files=[];
    for(const name of names) {
      if(performance.now()>=deadline) return null;
      const file=path.join(directory,name);
      const entry=await fs.lstat(file);
      if(!entry.isFile() || !privateItem(entry,0o600) || entry.nlink!==1 || entry.size>32768 || entry.mtimeMs>=cutoff) return null;
      const handle=await fs.open(file,constants.O_RDONLY|constants.O_NOFOLLOW);
      let event;
      try {
        const opened=await handle.stat();
        if(opened.ino!==entry.ino || opened.dev!==entry.dev) return null;
        const bytes=Buffer.alloc(32769);
        const {bytesRead}=await handle.read(bytes,0,bytes.length,0);
        if(bytesRead>32768) return null;
        event=JSON.parse(bytes.subarray(0,bytesRead).toString('utf8'));
      } finally {await handle.close();}
      if(event.schemaVersion!==1 || event.provider!==match[1] || !events[event.provider]?.has(event.eventName) || event.ownerPID!==pid
        || !identity(event.sessionID) || typeof event.ownerStartedAt!=='string' || !event.ownerStartedAt.trim()
        || !Number.isFinite(event.observedAt) || event.observedAt<=0 || event.observedAt>=cutoff
        || scopeName(event)!==scope) return null;
      files.push({name,ino:entry.ino,dev:entry.dev,mtime:entry.mtimeMs,size:entry.size});
    }
    return probe(pid)?{files,pid,ino:stat.ino,dev:stat.dev}:null;
  };
  const remove=async(directory,scope)=>{
    const snapshot=await expired(directory,scope,true);
    if(!snapshot) return;
    // Recheck the complete directory before touching files. A late writer or
    // interrupted attempt leaves its records in quarantine, never force-removed.
    const names=await limitedNames(directory,64);
    if(!names || names.join('\n')!==snapshot.files.map(x=>x.name).join('\n')) return;
    for(const file of snapshot.files) {
      if(performance.now()>=deadline || !probe(snapshot.pid)) return;
      const dir=await fs.lstat(directory), current=await fs.lstat(path.join(directory,file.name));
      if(!dir.isDirectory() || !privateItem(dir,0o700) || dir.ino!==snapshot.ino || dir.dev!==snapshot.dev
        || !current.isFile() || !privateItem(current,0o600) || current.ino!==file.ino || current.dev!==file.dev
        || current.mtimeMs!==file.mtime || current.size!==file.size) return;
      await fs.unlink(path.join(directory,file.name));
    }
    await fs.rmdir(directory); // A new or unknown file prevents removal.
    return true;
  };
  try {
    await fs.mkdir(gc,{mode:0o700}).catch(error=>{if(error.code!=='EEXIST') throw error;});
    const stat=await fs.lstat(gc);
    if(!stat.isDirectory() || !privateItem(stat,0o700)) return 0;
    // Overflow blocks new quarantine entries, never recovery of existing ones.
    const pending=await limitedNames(gc,128,true);
    let recovered=0;
    for(const name of pending) {
      if(performance.now()>=deadline || recovered>=4) break;
      const match=/^(.*)~[a-f0-9-]{36}$/.exec(name);
      if(match && scopePattern.test(match[1])) {
        if(await remove(path.join(gc,name),match[1]).catch(()=>false)) recovered++;
      }
    }
    if((await limitedNames(gc,124))===null) return 0;
    const candidates=await limitedNames(root);
    if(!candidates) return 0;
    for(const scope of candidates) {
      if(moved>=4 || performance.now()>=deadline) break;
      if(!scopePattern.test(scope)) continue;
      const directory=path.join(root,scope);
      try {
        if(!await expired(directory,scope)) continue;
        const target=path.join(gc,`${scope}~${randomUUID()}`);
        await fs.rename(directory,target);
        moved++;
        await afterQuarantine(target);
        await remove(target,scope);
      } catch { /* Concurrent collection or changed data: keep it, try later. */ }
    }
  } catch { /* Failed observation or cleanup must not manufacture free capacity. */ }
  return moved;
}

export async function saveEvent(root, event) {
  // WorkBuddy puts the parent's ID in child payloads. Exclude proven child
  // events before retention; filtering only in the Reader lets a busy child
  // evict every main-task record from the shared 64-event buffer.
  if (event.provider === 'workbuddy' && event.runtimeSessionID
      && event.runtimeSessionID !== event.sessionID) return undefined;
  await fs.mkdir(root, { recursive: true, mode: 0o700 });
  const directory = await fs.lstat(root);
  if (!directory.isDirectory() || directory.isSymbolicLink() || directory.uid !== process.getuid()) {
    throw new Error('Observer directory must be owned by this user');
  }
  await fs.chmod(root, 0o700);
  const scope = scopeName(event);
  const scopedRoot = path.join(root, scope);
  try { await fs.lstat(scopedRoot); } catch(error) {
    if(error.code!=='ENOENT') throw error;
    let names=await limitedNames(root);
    if(!names || names.filter(x=>x!=='.gc').length>=128) {
      await reclaimExpiredScopes(root);
      names=await limitedNames(root);
    }
    if(!names || names.filter(x=>x!=='.gc').length>=128) throw new Error('Observer scope limit reached');
  }
  await fs.mkdir(scopedRoot, { mode: 0o700 }).catch(error => { if (error.code !== 'EEXIST') throw error; });
  const scoped = await fs.lstat(scopedRoot);
  if (!scoped.isDirectory() || scoped.isSymbolicLink() || scoped.uid !== process.getuid() || (scoped.mode & 0o777) !== 0o700) {
    throw new Error('Observer session directory is not private');
  }
  root = scopedRoot;
  const name = `${String(event.observedAt).padStart(13, '0')}-${randomUUID()}.json`;
  const temporary = path.join(root, `.${randomUUID()}.tmp`);
  try {
    await fs.writeFile(temporary, JSON.stringify(event), { flag: 'wx', mode: 0o600 });
    await fs.rename(temporary, path.join(root, name));
  } finally { await fs.unlink(temporary).catch(() => {}); }
  // Bound ephemeral observation history. Never walk or delete arbitrary files.
  const entries = (await fs.readdir(root)).filter(x => /^\d{13}-[a-f0-9-]{36}\.json$/.test(x)).sort();
  await Promise.all(entries.slice(0, Math.max(0, entries.length - 64)).map(x => fs.unlink(path.join(root, x)).catch(() => {})));
  return path.join(scope, name);
}

async function main() {
  process.umask(0o077);
  const args = process.argv.slice(2);
  const option = name => args.includes(name) ? args[args.indexOf(name) + 1] : undefined;
  const provider = option('--provider');
  // CodeBuddy may inject nonempty UserPromptSubmit stdout into model context.
  const neutral = ['workbuddy', 'kimi'].includes(provider) ? '' : '{}\n';
  // A hook must finish promptly even if its producer never closes stdin.
  const deadline = setTimeout(() => { process.stdout.write(neutral); process.exit(0); }, 1800);
  try {
    const chunks = [];
    let size = 0;
    for await (const chunk of process.stdin) {
      size += chunk.length;
      if (size > 1024 * 1024) throw new Error('Hook input exceeds budget');
      chunks.push(chunk);
    }
    const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    const event = normalize(provider, input, option('--event'), findOwner(provider), Date.now(),
      provider === 'workbuddy' ? process.env.CODEBUDDY_SESSION_ID : undefined,
      provider === 'mistral' ? mistralDataRoot() : provider === 'kimi' ? option('--data-root') : undefined);
    const root = option('--output') ?? process.env.LOOPFWD_HOOK_ROOT ?? path.join(os.homedir(), 'Library/Application Support/LoopFwd/hook-events');
    if (!path.isAbsolute(root)) throw new Error('Observer path must be absolute');
    await saveEvent(root, event);
  } catch {
    // Generic diagnostic only: never echo input or change the provider result.
    process.stderr.write('LoopFwd observer could not record this event.\n');
  } finally {
    clearTimeout(deadline);
    process.stdout.write(neutral);
  }
}

// Node canonicalizes the module URL, but keeps the launch spelling in argv.
// macOS /var -> /private/var and explicit script symlinks must still execute.
let direct = false;
try { direct = process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url)); } catch {}
if (direct) await main();
