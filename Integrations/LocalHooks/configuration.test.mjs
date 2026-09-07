import test from 'node:test';
import assert from 'node:assert/strict';
import {promises as fs} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {createRequire} from 'node:module';
import {configure,editSettings,definitions,atomicWrite} from './configure-json-hooks.mjs';
const {parse}=createRequire(import.meta.url)('./vendor/jsonc-parser/main.js');

test('JSONC edits preserve user groups, comments, BOM and disable switches',()=>{
  for (const provider of ['gemini','qwen']) {
    const text='\uFEFF{\r\n  // preserve my comment\r\n  "disableAllHooks":true,\r\n  "hooksConfig":{"enabled":false},\r\n  "hooks":{"SessionStart":[{"matcher":"startup","hooks":[{"name":"user","command":"echo safe","type":"command"}]}]},\r\n  "custom":{"value":42},\r\n}\r\n';
    const defs=definitions(provider,"/node with 'quote",'/private/observer.mjs');
    const first=editSettings(text,provider,'install',{},defs);
    assert.equal(first.disabled,true);
    assert(first.text.startsWith('\uFEFF'));assert(first.text.includes('// preserve my comment\r\n'));
    assert.deepEqual(parse(first.text.slice(1)).hooks.SessionStart[0],parse(text.slice(1)).hooks.SessionStart[0]);
    assert.equal(editSettings(first.text,provider,'install',defs,defs).text,first.text);
    const removed=editSettings(first.text,provider,'remove',defs);
    assert.equal(parse(removed.text.slice(1)).custom.value,42);
    assert.equal(parse(removed.text.slice(1)).hooks.SessionStart.length,1);
    assert(removed.text.includes('// preserve my comment'));
  }
});

test('malformed settings and edited or duplicate observer definitions fail closed',()=>{
  const defs=definitions('qwen','/node','/observer');
  for(const text of ['{"hooks":[]}','{"hooks":{"SessionStart":{}}}','{"x":1,"x":2}','{bad']) {
    assert.throws(()=>editSettings(text,'qwen','install',{},defs));
  }
  const installed=editSettings('{}','qwen','install',{},defs).text;
  assert.throws(()=>editSettings(installed.replaceAll('/observer','/user-command'),'qwen','remove',defs),/observer_conflict/);
});

test('Cursor uses flat second-based hooks and preserves other commands and comments',()=>{
  const original='{\r\n  // keep my hooks\r\n  "version":1,\r\n  "custom":42,\r\n  "hooks":{"stop":[{"command":"echo user","loop_limit":null}]}\r\n}\r\n';
  const defs=definitions('cursor',"/node with 'quote",'/private/observer.mjs');
  const installed=editSettings(original,'cursor','install',{},defs);
  const config=parse(installed.text);
  assert.equal(config.version,1);assert.equal(config.custom,42);
  assert.deepEqual(config.hooks.stop[0],{command:'echo user',loop_limit:null});
  for(const [name,item]of Object.entries(defs)) {
    assert.equal(item.timeout,2);assert.equal(item.hooks,undefined);assert.equal(item.name,undefined);
    assert(item.command.includes(`loopfwd-observe-cursor-${name}`));
  }
  assert(installed.text.includes('// keep my hooks\r\n'));
  assert.equal(editSettings(installed.text,'cursor','install',defs,defs).text,installed.text);
  const removed=editSettings(installed.text,'cursor','remove',defs);
  assert.deepEqual(parse(removed.text).hooks.stop,[{command:'echo user',loop_limit:null}]);
  assert(removed.text.includes('// keep my hooks'));
  assert.equal(parse(editSettings('{}','cursor','install',{},defs).text).version,1);
  assert.throws(()=>editSettings('{"version":2}','cursor','install',{},defs),/unsupported_hooks_version/);
  for(const text of ['\uFEFF{}','{"hooks":{},}','{"url":"https://example.invalid"}','{"value":"a/*comment*/b"}'])
    assert.throws(()=>editSettings(text,'cursor','install',{},defs),/unsupported_cursor_jsonc/);
  assert.throws(()=>editSettings(installed.text.replaceAll('/private/observer.mjs','/changed/user.mjs'),'cursor','remove',defs),/observer_conflict/);
  for(const marker of ['--loopfwd-id loopfwd-observe-cursor-stop','"--loopfwd-id" "loopfwd-observe-cursor-stop"',"'--loopfwd-id'\n'loopfwd-observe-cursor-stop'"]) {
    const changed=JSON.stringify({version:1,hooks:{stop:[{command:'different-command '+marker,timeout:2}]}});
    assert.throws(()=>editSettings(changed,'cursor','install',defs,defs),/observer_conflict/);
    assert.throws(()=>editSettings(changed,'cursor','remove',defs),/observer_conflict/);
  }
});

test('Cursor installation and rollback target only hooks.json and remain removable without CLI',async t=>{
  const f=await fixture(t),config=path.join(f.root,'hooks.json');
  const original='{// Cursor comment\n"version":1,"hooks":{"stop":[{"command":"echo user"}]},"custom":42}\n';
  await fs.writeFile(config,original);
  const args={...f.args,provider:'cursor',config};
  const failed=await configure(args,async(file,data)=>{await atomicWrite(file,data);throw new Error('injected');});
  assert.equal(failed.ok,false);assert.equal(await fs.readFile(config,'utf8'),original);
  const result=await configure(args);assert.equal(result.ok,true);
  assert.equal(await fs.readFile(path.join(result.backupPath,'hooks.json'),'utf8'),original);
  assert.equal((await fs.stat(config)).mode&0o777,0o600);
  assert.equal(await fs.readFile(f.config,'utf8'),f.original,'Unrelated settings.json is unchanged');
  assert.equal((await configure({...args,operation:'check'})).complete,true);
  assert.equal((await configure(args)).changed,false);
  assert.equal((await configure({...args,operation:'remove',node:undefined,collector:undefined})).ok,true);
  assert.deepEqual(parse(await fs.readFile(config,'utf8')).hooks.stop,[{command:'echo user'}]);
  assert.equal(await fs.readFile(f.config,'utf8'),f.original);
  await assert.rejects(configure({...args,config:f.config}),/invalid_target/);
});

test('WorkBuddy uses nested seconds-based hooks and command ownership without touching user hooks',()=>{
  const original='{ // keep WorkBuddy comment\n"disableAllHooks":true,"url":"https://example.invalid/a","hooks":{"FinalStop":[{"matcher":"user","hooks":[{"type":"command","command":"echo user","name":"user"}]}]},}\n';
  const defs=definitions('workbuddy',"/node with 'quote",'/private/observer.mjs');
  assert.equal(Object.keys(defs).length,7);
  for(const [name,item] of Object.entries(defs)) {
    assert.equal(item.matcher,'');assert.equal(item.hooks.length,1);
    assert.equal(item.hooks[0].timeout,2);assert.equal(item.hooks[0].type,'command');
    assert.equal(item.hooks[0].name,undefined);
    assert(item.hooks[0].command.includes(`loopfwd-observe-workbuddy-${name}`));
  }
  const installed=editSettings(original,'workbuddy','install',{},defs);
  assert.equal(installed.disabled,true);assert(installed.text.includes('// keep WorkBuddy comment'));
  assert.equal(parse(installed.text).url,'https://example.invalid/a');
  assert.deepEqual(parse(installed.text).hooks.FinalStop[0],parse(original).hooks.FinalStop[0]);
  assert.equal(editSettings(installed.text,'workbuddy','install',defs,defs).text,installed.text);
  assert.throws(()=>editSettings(installed.text.replaceAll('/private/observer.mjs','/changed.mjs'),'workbuddy','remove',defs),/observer_conflict/);
  const removed=editSettings(installed.text,'workbuddy','remove',defs);
  assert.deepEqual(parse(removed.text).hooks.FinalStop,parse(original).hooks.FinalStop);
  assert.equal(parse(removed.text).disableAllHooks,true);
});

test('WorkBuddy BOM is rejected without edits, but exact removal remains recoverable',async t=>{
  const f=await fixture(t),args={...f.args,provider:'workbuddy'};
  const original='\uFEFF'+f.original;
  await fs.writeFile(f.config,original);
  for(const operation of ['install','check']) {
    const result=await configure({...args,operation});
    assert.equal(result.ok,false);assert.equal(result.code,'unsupported_workbuddy_jsonc_bom');
    assert.equal(await fs.readFile(f.config,'utf8'),original);
  }
  await fs.writeFile(f.config,f.original);
  assert.equal((await configure(args)).ok,true);
  await fs.writeFile(f.config,'\uFEFF'+await fs.readFile(f.config,'utf8'));
  const removed=await configure({...args,operation:'remove',node:undefined,collector:undefined});
  assert.equal(removed.ok,true);assert.equal(removed.installed,false);
  assert.equal(removed.warning,'unsupported_workbuddy_jsonc_bom');
  const text=await fs.readFile(f.config,'utf8');assert(text.startsWith('\uFEFF'));
  const settings=parse(text.slice(1));assert.equal(settings.custom,'untouched');
  assert(Object.values(settings.hooks).every(items=>items.length===0));
  const again=await configure({...args,operation:'remove'});
  assert.equal(again.changed,false);assert.equal(again.warning,removed.warning);
});

test('WorkBuddy install rollback and removal use private backups without a provider process',async t=>{
  const f=await fixture(t),args={...f.args,provider:'workbuddy'};
  const failed=await configure(args,async(file,data)=>{await atomicWrite(file,data);throw new Error('injected');});
  assert.equal(failed.ok,false);assert.equal(await fs.readFile(f.config,'utf8'),f.original);
  const result=await configure(args);assert.equal(result.ok,true);
  assert.equal(await fs.readFile(path.join(result.backupPath,'settings.json'),'utf8'),f.original);
  assert.equal((await fs.stat(f.config)).mode&0o777,0o600);
  assert.equal((await configure({...args,operation:'check'})).complete,true);
  assert.equal((await configure(args)).changed,false);
  const removed=await configure({...args,operation:'remove',node:undefined,collector:undefined});
  assert.equal(removed.ok,true);assert.equal(removed.installed,false);
  const restored=parse(await fs.readFile(f.config,'utf8'));
  assert.equal(restored.custom,'untouched');
  assert(Object.values(restored.hooks ?? {}).every(items=>items.length===0));
});

async function fixture(t) {
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'loopfwd-json-config-'));
  t.after(()=>fs.rm(root,{recursive:true,force:true}));
  const config=path.join(root,'settings.json'),collector=path.join(root,'source.mjs');
  const original='{//keep\n"custom":"untouched"}\n';
  await fs.writeFile(config,original);await fs.writeFile(collector,'// synthetic\n');
  return {root,config,collector,original,args:{provider:'qwen',operation:'install',config,collector,node:process.execPath}};
}

test('real transaction is idempotent, privately backed up and removable without CLI',async t=>{
  const f=await fixture(t);
  const result=await configure(f.args);
  assert.equal(result.ok,true);
  assert.equal(await fs.readFile(path.join(result.backupPath,'settings.json'),'utf8'),f.original);
  assert.equal((await fs.stat(f.config)).mode&0o777,0o600);
  assert.equal((await fs.stat(result.backupPath)).mode&0o777,0o700);
  assert.equal((await configure(f.args)).changed,false);
  assert.equal((await configure({...f.args,operation:'remove',node:undefined,collector:undefined})).ok,true);
  assert.equal(parse(await fs.readFile(f.config,'utf8')).custom,'untouched');
});

test('post-write failure restores only its own bytes and preserves intervening user edits',async t=>{
  const f=await fixture(t);
  const failed=await configure(f.args,async(file,data)=>{await atomicWrite(file,data);throw new Error('injected');});
  assert.equal(failed.ok,false);assert(failed.backupPath);
  assert.equal(await fs.readFile(f.config,'utf8'),f.original);
  const changed=await configure(f.args,async file=>{await atomicWrite(file,'{"userChanged":true}');});
  assert.equal(changed.ok,false);
  assert.equal(await fs.readFile(f.config,'utf8'),'{"userChanged":true}');
});

test('interrupted upgrade intent recognizes the previous installed configuration',async t=>{
  const f=await fixture(t);
  await configure(f.args);
  await fs.writeFile(f.collector,'// newer version\n');
  const failed=await configure(f.args,async()=>{throw new Error('injected before write');});
  assert.equal(failed.ok,false);
  assert.equal((await configure(f.args,async()=>{throw new Error('second failure');})).ok,false);
  assert.equal((await configure({...f.args,operation:'remove'})).ok,true);
});

test('symlinks and remaining transaction locks fail closed without automatic deletion',async t=>{
  const f=await fixture(t);
  const root=path.join(f.root,'.loopfwd-json-hooks');await fs.mkdir(root,{mode:0o700});
  const lock=path.join(root,'transaction.lock');
  await fs.writeFile(lock,JSON.stringify({pid:process.pid,createdAt:Date.now()}));
  await assert.rejects(configure(f.args),/configuration_locked/);
  await fs.writeFile(lock,JSON.stringify({pid:2147483647,createdAt:Date.now()}));
  await assert.rejects(configure(f.args),/configuration_locked/);
  // Explicit test-fixture recovery, not automatic production lock takeover.
  await fs.unlink(lock);
  assert.equal((await configure(f.args)).ok,true);
  await fs.rename(f.config,path.join(f.root,'actual.json'));
  await fs.symlink(path.join(f.root,'actual.json'),f.config);
  assert.equal((await configure(f.args)).code,'unsafe_file');
});

test('removal retains comments adjacent to the appended observer',()=>{
  const original='{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"echo user"}]} // user trailing comment\n]}}';
  const defs=definitions('gemini','/node','/observer');
  const installed=editSettings(original,'gemini','install',{},defs).text;
  const removed=editSettings(installed,'gemini','remove',defs).text;
  assert(removed.includes('// user trailing comment'));
  assert.equal(parse(removed).hooks.SessionStart.length,1);
});

test('missing collector is detected and repaired by reinstalling unchanged settings',async t=>{
  const f=await fixture(t);await configure(f.args);
  const manifest=JSON.parse(await fs.readFile(path.join(f.root,'.loopfwd-json-hooks/qwen.json')));
  await fs.unlink(manifest.collector);
  const check=await configure({...f.args,operation:'check'});
  assert.equal(check.installed,true);assert.equal(check.runtimeAvailable,false);
  assert.equal((await configure(f.args)).ok,true);
  assert.equal((await configure({...f.args,operation:'check'})).runtimeAvailable,true);
});
