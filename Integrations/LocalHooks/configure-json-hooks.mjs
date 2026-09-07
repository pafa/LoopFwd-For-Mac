// Explicit-action configuration only. Never loads a provider's settings loader.
import { promises as fs, constants } from 'node:fs';
import path from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
const {parseTree, getNodeValue, findNodeAtLocation, createScanner, SyntaxKind, modify, applyEdits} = createRequire(import.meta.url)('./vendor/jsonc-parser/main.js');
export const profiles = {
  gemini: {version:'0.58.0', events:['SessionStart','BeforeAgent','BeforeModel','AfterModel','BeforeTool','AfterTool','AfterAgent','Notification','SessionEnd']},
  qwen: {version:'0.23.0', events:['SessionStart','UserPromptSubmit','MessageDisplay','PreToolUse','PostToolUse','PostToolUseFailure','Notification','Stop','StopFailure','SessionEnd']},
  cursor: {version:'2026.09.02-c22c1a3', events:['sessionStart','beforeSubmitPrompt','afterAgentThought','afterAgentResponse','preToolUse','postToolUse','postToolUseFailure','stop','sessionEnd']},
  workbuddy: {version:'2.137.1', events:['UserPromptSubmit','PreToolUse','PostToolUse','PermissionRequest','Stop','FinalStop','StopFailure']},
};
const object = x => x && typeof x === 'object' && !Array.isArray(x);
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const same = (a,b) => JSON.stringify(a) === JSON.stringify(b);
const quote = value => `'${value.replaceAll("'", "'\\''")}'`;

function parse(text) {
  const errors=[];
  const tree=parseTree(text, errors, {allowTrailingComma:true});
  if (errors.length || tree?.type !== 'object') throw new Error('invalid_jsonc');
  function check(node) {
    if (node.type === 'object') {
      const keys = node.children.map(x=>x.children[0].value);
      if (new Set(keys).size !== keys.length || keys.includes('__proto__')) throw new Error('ambiguous_jsonc_keys');
    }
    for (const child of node.children ?? []) check(child);
  }
  check(tree);
  return getNodeValue(tree);
}

function validateCursorSyntax(text, expected) {
  // The pinned CLI's JSONC reader strips comments before JSON.parse. It does
  // not accept BOM/trailing commas, and comment markers inside values can be
  // misread. Refuse incompatible input instead of changing the user's values.
  try {
    const effective=JSON.parse(text.replace(/\/\/.*$/gm,'').replace(/\/\*[\s\S]*?\*\//g,''));
    if(!same(effective,expected)) throw new Error('different_values');
  } catch {throw new Error('unsupported_cursor_jsonc');}
}

export function definitions(provider, node, collector) {
  if (!profiles[provider]) throw new Error('unsupported_provider');
  const command=[node,collector,'--provider',provider].map(quote).join(' ');
  if(provider==='cursor') return Object.fromEntries(profiles.cursor.events.map(event=>[event,
    {command:command+' '+['--loopfwd-id',`loopfwd-observe-cursor-${event}`].map(quote).join(' '),timeout:2}]));
  if(provider==='workbuddy') return Object.fromEntries(profiles.workbuddy.events.map(event=>[event,
    {matcher:'',hooks:[{type:'command',command:command+' '+['--loopfwd-id',`loopfwd-observe-workbuddy-${event}`].map(quote).join(' '),timeout:2}]}]));
  return Object.fromEntries(profiles[provider].events.map(event=>[event,
    {hooks:[{type:'command',name:`loopfwd-observe-${provider}-${event}`,command,timeout:2000}]}]));
}

export function editSettings(original, provider, operation, previous={}, desired={}, pendingPrevious={}) {
  if (!profiles[provider] || !['install','remove','check'].includes(operation)) throw new Error('invalid_operation');
  const bom=original.startsWith('\uFEFF') ? '\uFEFF' : '';
  // Pinned WorkBuddy JsonUtils rejects BOM. Never silently rewrite it, but
  // allow exact-owned removal so an already broken setup can be recovered.
  const warning=provider==='workbuddy' && bom ? 'unsupported_workbuddy_jsonc_bom' : undefined;
  if(warning && operation!=='remove') throw new Error(warning);
  let text=original.slice(bom.length);
  const settings=parse(text);
  if(provider==='cursor') validateCursorSyntax(original,settings);
  if(provider==='cursor' && settings.version!==undefined && settings.version!==1) throw new Error('unsupported_hooks_version');
  if (settings.hooks !== undefined && !object(settings.hooks)) throw new Error('invalid_hooks');
  const prefix=`loopfwd-observe-${provider}-`;
  const matched = new Map();
  for (const [event, items] of Object.entries(settings.hooks ?? {})) {
    if (!Array.isArray(items)) throw new Error('invalid_event_array');
    for (let index=0; index<items.length;index++) {
      const item=items[index];
      if(provider==='cursor' ? !object(item) : !Array.isArray(item?.hooks)) throw new Error('invalid_hook_definition');
      const ownsCommand=command=>typeof command==='string' && command.includes('--loopfwd-id') && command.includes(prefix);
      const owned=provider==='cursor' ? ownsCommand(item.command)
        : item.hooks.some(h=>provider==='workbuddy' ? ownsCommand(h?.command) : typeof h?.name === 'string' && h.name.startsWith(prefix));
      if (!owned) continue;
      if (matched.has(event) || (!same(item, previous[event]) && !same(item, desired[event]) && !same(item,pendingPrevious[event]))) throw new Error('observer_conflict');
      matched.set(event, index);
    }
  }
  const disabled = provider === 'gemini' ? settings.hooksConfig?.enabled === false
    || (settings.hooksConfig?.disabled ?? []).some?.(x=>typeof x === 'string' && x.startsWith(prefix)) === true
    : settings.disableAllHooks === true;
  const matchedDefinitions=Object.fromEntries([...matched].map(([event,index])=>[event,settings.hooks[event][index]]));
  if (operation === 'check') return {text:original, installed:matched.size>0, complete:matched.size===profiles[provider].events.length, disabled, matchedDefinitions};
  const indent=/\n([ \t]+)"/.exec(text)?.[1] ?? '  ';
  const options={formattingOptions:{insertSpaces:!indent.includes('\t'),tabSize:Math.min(indent.length,8),eol:text.includes('\r\n')?'\r\n':'\n'}};
  const change=(where,value,insert=false)=> {text=applyEdits(text,modify(text,where,value,{...options,isArrayInsertion:insert}));};
  if(provider==='cursor' && operation==='install' && settings.version===undefined) change(['version'],1);
  for (const [event,index] of matched) {
    if (operation==='install' && same(settings.hooks[event][index], desired[event])) continue;
    // jsonc-parser's array deletion can consume adjacent user comments.
    // Delete only our AST node and a separator token; retain all trivia.
    const array=findNodeAtLocation(parseTree(text,[],{allowTrailingComma:true}),['hooks',event]);
    const node=array.children[index];
    const scanner=createScanner(text,true);
    scanner.setPosition(node.offset+node.length);
    let comma=scanner.scan()===SyntaxKind.CommaToken?scanner.getTokenOffset():null;
    if(comma===null && index>0) {
      const previous=array.children[index-1];scanner.setPosition(previous.offset+previous.length);
      if(scanner.scan()===SyntaxKind.CommaToken) comma=scanner.getTokenOffset();
    }
    const edits=[{offset:node.offset,length:node.length,content:''}];
    if(comma!==null) edits.push({offset:comma,length:1,content:''});
    text=applyEdits(text,edits);
  }
  if (operation==='install') {
    for (const [event,item] of Object.entries(desired)) {
      const current=parse(text).hooks?.[event];
      if (current?.some(x=>same(x,item))) continue;
      if (current === undefined) change(['hooks',event],[item]);
      else change(['hooks',event,current.length],item,true);
    }
  }
  const result=parse(text);
  if(provider==='cursor') validateCursorSyntax(bom+text,result);
  return {text:bom+text, installed:operation==='install', complete:operation==='install', disabled, matchedDefinitions, warning};
}

async function read(file, optional=false) {
  let stat;
  try {stat=await fs.lstat(file);} catch(error) {if(optional && error.code==='ENOENT') return null;throw error;}
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid!==process.getuid() || stat.size>1024*1024) throw new Error('unsafe_file');
  return fs.readFile(file);
}
async function directory(dir) {
  await fs.mkdir(dir,{mode:0o700}).catch(error=>{if(error.code!=='EEXIST') throw error;});
  const stat=await fs.lstat(dir);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid!==process.getuid()) throw new Error('unsafe_directory');
  await fs.chmod(dir,0o700);
}
export async function atomicWrite(file,bytes) {
  const temporary=path.join(path.dirname(file),`.loopfwd-${randomUUID()}.tmp`);
  const handle=await fs.open(temporary,'wx',0o600);
  try {await handle.writeFile(bytes);await handle.sync();await handle.close();await fs.rename(temporary,file);}
  finally {await handle.close().catch(()=>{});await fs.unlink(temporary).catch(()=>{});}
}

async function acquireLock(lockPath) {
  try {return await fs.open(lockPath,'wx',0o600);} catch(error) {
    if(error.code!=='EEXIST') throw error;
  }
  // Do not unlink a supposedly dead owner's lock: concurrent recovery could
  // delete a new live lock. Interrupted transactions require explicit recovery.
  throw new Error('configuration_locked_review_backup_folder');
}

export async function configure({provider,operation,config,node,collector}, write=atomicWrite) {
  const configName=provider==='cursor'?'hooks.json':'settings.json';
  if (!profiles[provider] || !path.isAbsolute(config) || path.basename(config)!==configName) throw new Error('invalid_target');
  const root=path.join(path.dirname(config),'.loopfwd-json-hooks');
  const manifestPath=path.join(root,`${provider}.json`);
  let lock,backupPath,original,edited;
  const lockPath=path.join(root,'transaction.lock');
  if(operation!=='check') {await directory(root);lock=await acquireLock(lockPath);}
  try {
  if(lock) await lock.writeFile(JSON.stringify({pid:process.pid,createdAt:Date.now()}));
  original=await read(config,true);
  const originalText=original ? new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(original) : '{}\n';
  const manifestBytes=await read(manifestPath,true);
  const manifest=manifestBytes ? JSON.parse(manifestBytes) : null;
  if (manifest && (manifest.schemaVersion!==1 || manifest.provider!==provider || !object(manifest.definitions))) throw new Error('invalid_manifest');
  let desired={}, code, destination;
  if (operation==='install') {
    if (!node || !path.isAbsolute(node) || !collector || !path.isAbsolute(collector)) throw new Error('missing_runtime');
    await fs.access(node,constants.X_OK);
    code=await read(collector);
    destination=path.join(root,`${hash(code)}.mjs`);
    desired=definitions(provider,node,destination);
  }
  edited=editSettings(originalText,provider,operation,manifest?.definitions,desired,manifest?.previousDefinitions);
  let runtimeAvailable=false;
  if(manifest?.collector && manifest.collector===path.join(root,`${manifest.collectorHash}.mjs`)) {
    const runtime=await read(manifest.collector,true);
    runtimeAvailable=runtime!==null && hash(runtime)===manifest.collectorHash;
  }
  if(operation==='check') return {ok:true,changed:false,installed:edited.installed,complete:edited.complete,runtimeAvailable,disabled:edited.disabled};
  const existing=destination?await read(destination,true):null;
  if(existing && !existing.equals(code)) throw new Error('collector_changed');
  if(edited.text===originalText && (operation==='remove' || (existing && runtimeAvailable && manifest))) {
    return {ok:true,changed:false,installed:edited.installed,complete:edited.complete,runtimeAvailable,disabled:edited.disabled,warning:edited.warning};
  }
    backupPath=path.join(root,`backup-${randomUUID()}`);
    await directory(backupPath);
    await atomicWrite(path.join(backupPath,configName),original ?? Buffer.alloc(0));
    await atomicWrite(path.join(backupPath,'original.json'),JSON.stringify({existed:original!==null,manifest:manifest??null}));
    if (operation==='install') {
      if(!existing) await atomicWrite(destination,code);
      // Save intent before the settings write so interrupted installs remain removable.
      await atomicWrite(manifestPath,JSON.stringify({schemaVersion:1,provider,definitions:desired,
        previousDefinitions:edited.matchedDefinitions,collector:destination,collectorHash:hash(code)}));
    }
    const current=await read(config,true);
    if ((current===null)!==(original===null) || (current && !current.equals(original))) throw new Error('config_changed');
    await write(config,Buffer.from(edited.text));
    if (!(await read(config)).equals(Buffer.from(edited.text))) throw new Error('write_verification_failed');
    return {ok:true,changed:true,installed:edited.installed,complete:edited.complete,runtimeAvailable:operation==='install',disabled:edited.disabled,backupPath,warning:edited.warning};
  } catch(error) {
    // Never overwrite an intervening user change. Restore only our exact bytes.
    const current=await read(config,true).catch(()=>null);
    if(edited && original!==undefined && current?.equals(Buffer.from(edited.text))) {
      if(original===null) await fs.unlink(config);
      else await atomicWrite(config,original);
    }
    return {ok:false,code:/^[a-z_]+$/.test(error.message)?error.message:'configuration_failed',backupPath};
  } finally {if(lock) {await lock.close();await fs.unlink(lockPath);}}
}

if (process.argv[1] && path.resolve(process.argv[1])===fileURLToPath(import.meta.url)) {
  process.umask(0o077);
  const args=process.argv.slice(2), option=name=>args.includes(name)?args[args.indexOf(name)+1]:undefined;
  try {
    if(Number(process.versions.node.split('.')[0])<24) throw new Error('node_24_required');
    const result=await configure({operation:args[0],provider:option('--provider'),config:option('--config'),node:option('--node'),collector:option('--collector')});
    process.stdout.write(JSON.stringify(result)+'\n');process.exitCode=result.ok?0:1;
  } catch(error) {process.stdout.write(JSON.stringify({ok:false,code:/^[a-z_]+$/.test(error.message)?error.message:'configuration_failed'})+'\n');process.exitCode=1;}
}
