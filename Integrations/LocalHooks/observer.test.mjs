import test from 'node:test';
import assert from 'node:assert/strict';
import { promises as fs } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { normalize, findOwner, findWorkBuddyOwner, workBuddyCLIApp, saveEvent, reclaimExpiredScopes, ownerHasExited, mistralDataRoot } from './observe-hook.mjs';

test('Kimi lifecycle is identity only and uses the configured root, never payload or prompts', async () => {
  const input={hook_event_name:'SessionHeartbeat',session_id:'session-1',cwd:'/synthetic/project',client_type:'kimi_code_cli',
    providerDataRoot:'/wrong',session_title:'private title',prompt:'private prompt',uptime_ms:90000,timestamp:new Date().toISOString()};
  const event=normalize('kimi',input,undefined,{pid:42,startedAt:'birth'},1700000000000,undefined,'/selected/kimi');
  assert.equal(event.providerDataRoot,'/selected/kimi');
  assert.deepEqual(Object.keys(event).sort(),['schemaVersion','provider','sessionID','eventName','observedAt','ownerPID','ownerStartedAt','providerDataRoot','cwd','clientType'].sort());
  for(const patch of [{client_type:'cli'},{client_type:'unknown'},{hook_event_name:'Stop'}, {parent_session_id:'parent'}, {agent_id:'child'}, {cwd:'relative'}]) {
    assert.throws(()=>normalize('kimi',{...input,...patch},undefined,{},Date.now(),undefined,'/selected/kimi'));
  }
  for(const root of [undefined,'relative','/bad\0root','/'+ 'a'.repeat(4096)]) {
    assert.throws(()=>normalize('kimi',input,undefined,{},Date.now(),undefined,root));
  }
  const temporary=await fs.mkdtemp(path.join(os.tmpdir(),'loopfwd-kimi-event-'));
  try {
    const saved=await saveEvent(temporary,event);
    assert.equal((await fs.stat(path.join(temporary,saved))).mode&0o777,0o600);
    assert.equal((await fs.stat(path.dirname(path.join(temporary,saved)))).mode&0o777,0o700);
  } finally {await fs.rm(temporary,{recursive:true,force:true});}
});

test('Kimi owner matches exact renamed title and not lookalikes or command mentions',()=>{
  const read=command=>pid=>pid===30?{parent:20,command:'/bin/sh -c observer'}:pid===20?{parent:1,command,startedAt:'birth'}:undefined;
  assert.deepEqual(findOwner('kimi',30,read('kimi-code')),{pid:20,startedAt:'birth'});
  for(const command of ['kimi-code helper','kimi-code-helper','echo kimi-code','node other.js kimi-code']) {
    assert.equal(findOwner('kimi',30,read(command)),undefined);
  }
  assert.equal(findOwner('kimi',30,pid=>({parent:1,command:'kimi-code'})),undefined);
});

test('the actual observer entrypoint also runs through a script symlink',async()=>{
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'loopfwd-kimi-entry-'));
  try {
    const entry=path.join(root,'observer-link.mjs');
    await fs.symlink(fileURLToPath(new URL('./observe-hook.mjs',import.meta.url)),entry);
    const output=path.join(root,'events');
    const run=spawnSync(process.execPath,[entry,'--provider','kimi','--data-root',root,'--output',output],{
      encoding:'utf8',input:JSON.stringify({hook_event_name:'SessionStart',session_id:'synthetic',cwd:root,client_type:'kimi_code_cli'}),
      env:{PATH:'/usr/bin:/bin'},timeout:3000});
    assert.equal(run.status,0); assert.equal(run.stdout,''); assert.equal(run.stderr,'');
    const scopes=await fs.readdir(output); assert.equal(scopes.length,1);
    const files=await fs.readdir(path.join(output,scopes[0])); assert.equal(files.length,1);
    const event=JSON.parse(await fs.readFile(path.join(output,scopes[0],files[0]),'utf8'));
    assert.equal(event.ownerPID,null,'test host must not impersonate an official provider');
  } finally {await fs.rm(root,{recursive:true,force:true});}
});

test('WorkBuddy requires a bundle-qualified CLI and a birth-matched app ancestor', () => {
  const app='/Applications/Work Buddy.app', cli=app+'/Contents/Resources/app.asar.unpacked/cli/bin/codebuddy';
  const command='/opt/node '+cli+' --serve --no-session-persistence';
  assert.equal(workBuddyCLIApp(command),app);
  const fallback=app+'/Contents/Resources/app.asar.unpacked/cli/dist/codebuddy.js';
  assert.equal(workBuddyCLIApp('/opt/node '+fallback+' --serve'),app);
  assert.equal(workBuddyCLIApp('/opt/node other.js '+fallback),undefined);
  assert.equal(workBuddyCLIApp('/opt/node '+fallback+'.bak --serve'),undefined);
  assert.equal(workBuddyCLIApp(app+'/Contents/Frameworks/WorkBuddy Helper.app/Contents/MacOS/WorkBuddy Helper '+cli+' --serve'),app);
  assert.equal(workBuddyCLIApp(app+'/Contents/MacOS/WorkBuddy '+cli+' --serve'),app);
  assert.equal(workBuddyCLIApp(cli+' --prewarm --prewarm-id wb-pool-1'),app);
  for(const invalid of ['/opt/node other.js '+cli, '/bin/echo '+cli, '/usr/bin/codebuddy --serve', '/opt/node -e '+cli,
    app+'/Contents/MacOS/WorkBuddy -e '+cli, app+'/Contents/MacOS/WorkBuddy other.js '+cli,
    '/bin/echo '+app+'/Contents/MacOS/WorkBuddy '+cli,
    app+'/Contents/Frameworks/WorkBuddy Helper.app/Contents/MacOS/WorkBuddy Helper -e '+cli]) {
    assert.equal(workBuddyCLIApp(invalid),undefined,invalid);
  }
  const processes={40:{parent:30,command:'/bin/sh -c observe'},30:{parent:20,command,startedAt:'cli-birth'},
    20:{parent:1,command:app+'/Contents/MacOS/WorkBuddy',startedAt:'host-birth'}};
  const validate=p=>p===app?{providerVersion:'2.137.1'}:undefined;
  const read=pid=>processes[pid];
  assert.deepEqual(findWorkBuddyOwner(40,read,validate),{pid:30,startedAt:'cli-birth',appPath:app,providerVersion:'2.137.1',hostPID:20,hostStartedAt:'host-birth'});
  assert.equal(findWorkBuddyOwner(40,read,()=>undefined),undefined,'same name is not the bundle identity');
  let cliReads=0;
  assert.equal(findWorkBuddyOwner(40,pid=>pid===30 && ++cliReads>1?{...read(pid),startedAt:'reused'}:read(pid),validate),undefined);
  processes[30].parent=1;
  assert.equal(findWorkBuddyOwner(40,read,validate),undefined,'detached prewarm must not invent a host');
});

test('WorkBuddy preserves generation and actual child identity but no payload or false result', () => {
  const owner={pid:30,startedAt:'birth',appPath:'/Applications/WorkBuddy.app',hostPID:20,hostStartedAt:'host-birth',providerVersion:'2.137.1'};
  const input={session_id:'main',generation_id:'gen',agent_id:'named-main',hook_event_name:'FinalStop',
    final_stop_reason:'completed',provider_version:'pretend-version',timestamp:new Date().toISOString(),
    prompt:'private text',tool_input:{key:'private'},transcript_path:'/synthetic/session.jsonl'};
  const event=normalize('workbuddy',input,undefined,owner,1000,'child');
  assert.equal(event.runtimeSessionID,'child');assert.equal(event.sessionID,'main');
  assert.equal(event.agentID,'named-main');assert.equal(event.generationID,'gen');
  assert.equal(event.providerVersion,'2.137.1');assert.equal(event.sourceAt,undefined);
  assert.equal(event.stopReason,'completed');assert.equal(JSON.stringify(event).includes('private'),false);
  for(const reason of ['completed','cancelled','failed','interrupted']) {
    assert.equal(normalize('workbuddy',{...input,final_stop_reason:reason},undefined,owner,1000,'main').stopReason,reason);
  }
  for(const eventName of ['Stop','StopFailure','PreToolUse','PermissionRequest','PostToolUse']) {
    assert.equal(normalize('workbuddy',{...input,hook_event_name:eventName},undefined,owner,1000,'main').stopReason,undefined);
  }
  assert.equal(normalize('workbuddy',input).providerVersion,undefined,'expected or payload version is not host version');
  assert.equal(normalize('workbuddy',input).runtimeSessionID,undefined,'unknown main/child is not main');
});

test('WorkBuddy child bursts cannot evict main-session observation', async t => {
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'loopfwd-workbuddy-retention-'));
  t.after(()=>fs.rm(root,{recursive:true}));
  const owner={pid:30,startedAt:'birth',appPath:'/Applications/WorkBuddy.app',hostPID:20,hostStartedAt:'host-birth',providerVersion:'2.137.1'};
  const input={session_id:'main',agent_id:'named-main',hook_event_name:'PostToolUse'};
  const main=normalize('workbuddy',input,undefined,owner,1000,'main');
  const saved=await saveEvent(root,main);
  for(let i=0;i<80;i++) {
    const child=normalize('workbuddy',input,undefined,owner,1001+i,'child-'+i);
    assert.equal(await saveEvent(root,child),undefined);
  }
  const scopes=await fs.readdir(root);assert.equal(scopes.length,1);
  assert.equal((await fs.readdir(path.join(root,scopes[0]))).length,1);
  assert.deepEqual(JSON.parse(await fs.readFile(path.join(root,saved),'utf8')),JSON.parse(JSON.stringify(main)));
});

test('WorkBuddy real collector success and failure emit empty neutral stdout', async t => {
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'loopfwd-workbuddy-hook-'));
  t.after(()=>fs.rm(root,{recursive:true}));
  const script=fileURLToPath(new URL('./observe-hook.mjs',import.meta.url));
  for(const input of ['{broken',JSON.stringify({session_id:'main',hook_event_name:'UserPromptSubmit',prompt:'secret'})]) {
    const result=spawnSync(process.execPath,[script,'--provider','workbuddy','--output',root],{
      input,encoding:'utf8',timeout:4000,env:{...process.env,CODEBUDDY_SESSION_ID:'main'},
    });
    assert.equal(result.status,0);assert.equal(result.stdout,'');assert.equal(result.stderr.includes('secret'),false);
  }
  const scopes=await fs.readdir(root);assert.equal(scopes.length,1);
  const scope=path.join(root,scopes[0]);const files=await fs.readdir(scope);
  const file=path.join(scope,files[0]),event=JSON.parse(await fs.readFile(file,'utf8'));
  assert.equal(event.ownerPID,null,'synthetic host must stay unbound');assert.equal(event.runtimeSessionID,'main');
  assert.equal((await fs.stat(file)).mode&0o777,0o600);assert.equal(JSON.stringify(event).includes('secret'),false);
});

test('normalizes four official field families without retaining sensitive content', () => {
  for (const [provider, eventName] of [['mistral', 'pre_tool'], ['gemini', 'BeforeAgent'], ['qwen', 'PreToolUse'], ['copilot', 'preToolUse']]) {
    const event = normalize(provider, { session_id: 'a-1', hook_event_name: eventName, prompt: 'secret',
      tool_input: { api_key: 'secret' }, tool_name: 'x'.repeat(200) }, undefined, { pid: 7, startedAt: 'start' }, 100);
    assert.equal(event.sessionID, 'a-1');
    assert.equal(event.toolName.length, 128);
    assert.equal(event.ownerPID, 7);
    assert.equal(JSON.stringify(event).includes('secret'), false);
  }
  assert.throws(() => normalize('mistral', { session_id: '../escape', hook_event_name: 'pre_tool' }));
  assert.throws(() => normalize('mistral', { session_id: 'a', hook_event_name: 'success' }));
});

test('walks shell parents but does not bind arbitrary Python or argument mentions', () => {
  const processes = { 4: { parent: 3, command: '/bin/sh -c observe' }, 3: { parent: 1, command: '/bin/python3 /opt/bin/vibe', startedAt: 'start' } };
  assert.deepEqual(findOwner('mistral', 4, pid => processes[pid]), { pid: 3, startedAt: 'start' });
  processes[3].command = '/bin/python3 random.py vibe';
  assert.equal(findOwner('mistral', 4, pid => processes[pid]), undefined);
});

test('Cursor preserves conversation/generation boundaries without task content or invented clocks', () => {
  const base={conversation_id:randomUUID(),session_id:'runtime-not-conversation',generation_id:randomUUID(),
    cursor_version:'2026.09.02-c22c1a3',workspace_roots:['/synthetic/project'],text:'secret thought',
    prompt:'secret prompt',user_email:'secret@example.invalid',tool_input:{token:'secret'},timestamp:new Date().toISOString()};
  for(const eventName of ['sessionStart','beforeSubmitPrompt','afterAgentThought','afterAgentResponse','preToolUse','postToolUse','postToolUseFailure','stop','sessionEnd']) {
    const event=normalize('cursor',{...base,hook_event_name:eventName,status:'completed',loop_count:2},undefined,{pid:23,startedAt:'birth'},1000);
    assert.equal(event.sessionID,base.conversation_id);
    assert.equal(event.generationID,base.generation_id);
    assert.equal(event.providerVersion,base.cursor_version);
    assert.equal(event.sourceAt,undefined,'Cursor does not provide a verified source clock');
    assert.equal(event.cwd,'/synthetic/project');
    assert.equal(event.hasModelContent,['afterAgentThought','afterAgentResponse'].includes(eventName));
    assert.equal(event.stopReason,eventName==='stop'?'completed':undefined);
    assert.equal(JSON.stringify(event).includes('secret'),false);
  }
  assert.throws(()=>normalize('cursor',{session_id:'wrong-runtime-id',hook_event_name:'stop'}));
  assert.throws(()=>normalize('cursor',{...base,hook_event_name:'subagentStop'}));
  const child=normalize('cursor',{...base,hook_event_name:'afterAgentThought',parent_conversation_id:'parent'});
  assert.equal(child.parentSessionID,'parent');
  const multi=normalize('cursor',{...base,hook_event_name:'stop',workspace_roots:['/a','/b'],status:'unknown',loop_count:-1});
  assert.equal(multi.cwd,undefined);assert.equal(multi.stopReason,undefined);assert.equal(multi.loopCount,undefined);
  assert.deepEqual(findOwner('cursor',23,()=>({command:'/opt/cursor-agent --use-system-ca /opt/index.js',parent:1,startedAt:'birth'})),{pid:23,startedAt:'birth'});
  assert.equal(findOwner('cursor',23,()=>({command:'/opt/node other.js cursor-agent',parent:1,startedAt:'birth'})),undefined);
  assert.equal(findOwner('cursor',23,()=>({command:'/Applications/Cursor.app/Contents/MacOS/Cursor',parent:1,startedAt:'birth'})),undefined);
});

test('captures source clocks and streaming metadata without content or parameters', () => {
  const now = Date.now();
  const base = {session_id:'session', timestamp:new Date(now - 100).toISOString()};
  const gemini = normalize('gemini', {...base, hook_event_name:'AfterModel', llm_response:{candidates:[{content:{parts:['secret output']}}]}});
  assert.equal(gemini.hasModelContent, true);
  assert.equal(gemini.sourceAt, now - 100);
  assert.equal(JSON.stringify(gemini).includes('secret'), false);
  assert.equal(normalize('gemini', {...base, hook_event_name:'AfterModel', llm_response:{candidates:[{content:{parts:[{text:'SDK format is not Hook format'}]}}]}}).hasModelContent, false);
  const qwen = normalize('qwen', {...base, hook_event_name:'MessageDisplay', message_id:'m1', is_final:false, displayed_text:'secret output', submitted_prompt:'secret task'});
  assert.equal(qwen.messageID, 'm1');
  assert.equal(qwen.hasSubmittedPrompt, true);
  assert.equal(qwen.isFinal, false);
  assert.equal(JSON.stringify(qwen).includes('secret'), false);
  assert.equal(normalize('qwen', {...base, hook_event_name:'StopFailure', error:'secret error details'}).failureCode, undefined);
  for (const error of ['loop_detected','rate_limit','authentication_failed','billing_error','invalid_request','server_error','max_output_tokens','unknown']) {
    assert.equal(normalize('qwen', {...base, hook_event_name:'StopFailure', error}).failureCode, error);
  }
});

test('recognizes the exact official Mistral process title after setproctitle', () => {
  const read = command => () => ({parent:1, startedAt:'runtime birth', command});
  assert.deepEqual(findOwner('mistral', 123, read('Vibe CLI   ')), {pid:123, startedAt:'runtime birth'});
  for (const command of ['Vibe CLI Helper', 'Other Vibe CLI', 'node other.js Vibe CLI', 'echo Vibe CLI', 'Vibe CLI --eval']) {
    assert.equal(findOwner('mistral', 123, read(command)), undefined);
  }
  assert.equal(findOwner('qwen', 123, read('Vibe CLI')), undefined);
  assert.equal(findOwner('mistral', 123, () => ({parent:1, command:'Vibe CLI'})), undefined);
  const chain = {
    124: {parent:123, startedAt:'shell birth', command:'/bin/sh -c observer'},
    123: {parent:1, startedAt:'runtime birth', command:'Vibe CLI'},
  };
  assert.deepEqual(findOwner('mistral', 124, pid=>chain[pid]), {pid:123, startedAt:'runtime birth'});
});

test('Mistral data root comes only from the observer environment and remains bounded', async t => {
  assert.equal(mistralDataRoot({}, '/cwd', '/fixture-home'), '/fixture-home/.vibe');
  assert.equal(mistralDataRoot({VIBE_HOME:'relative folder'}, '/cwd', '/home'), '/cwd/relative folder');
  assert.equal(mistralDataRoot({VIBE_HOME:'~/custom'}, '/cwd', '/fixture-home'), '/fixture-home/custom');
  assert.throws(() => mistralDataRoot({VIBE_HOME:'x'.repeat(4097)}));
  assert.throws(() => mistralDataRoot({VIBE_HOME:'\0'}));
  assert.throws(() => mistralDataRoot({VIBE_HOME:'~another-user/custom'}));
  const input={session_id:'fixture', hook_event_name:'post_agent', providerDataRoot:'/untrusted'};
  assert.equal(normalize('mistral',input,undefined,undefined).providerDataRoot, undefined);
  assert.equal(normalize('mistral',input,undefined,undefined,Date.now(),undefined,'/actual').providerDataRoot, '/actual');
  assert.equal(normalize('qwen',{...input,hook_event_name:'Stop'},undefined,undefined,Date.now(),undefined,'/actual').providerDataRoot, undefined);
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'loopfwd-mistral-env-'));
  t.after(()=>fs.rm(root,{recursive:true}));
  const output=path.join(root,'events');
  const run=spawnSync(process.execPath,[fileURLToPath(new URL('./observe-hook.mjs',import.meta.url)),'--provider','mistral','--output',output],{
    input:JSON.stringify(input),encoding:'utf8',timeout:4000,
    env:{PATH:'/usr/bin:/bin',VIBE_HOME:path.join(root,'custom home')},
  });
  assert.equal(run.status,0); assert.deepEqual(JSON.parse(run.stdout),{});
  const scope=path.join(output,(await fs.readdir(output))[0]);
  const event=JSON.parse(await fs.readFile(path.join(scope,(await fs.readdir(scope))[0]),'utf8'));
  assert.equal(event.providerDataRoot,path.join(root,'custom home'));
});

test('recognizes actual official node entrypoints without matching argument mentions', () => {
  for (const [provider, script] of [['gemini','@google/gemini-cli/bundle/gemini.js'], ['qwen','@qwen-code/qwen-code/cli-entry.js'], ['qwen','@qwen-code/qwen-code/cli.js']]) {
    const read = () => ({parent:1, startedAt:'birth', command:`/opt/node /isolated/node_modules/${script}`});
    assert.deepEqual(findOwner(provider, 123, read), {pid:123, startedAt:'birth'});
    assert.equal(findOwner(provider, 123, () => ({...read(), command:`/opt/node other.js /isolated/node_modules/${script}`})), undefined);
    for (const flag of ['--expose-gc', '--max-old-space-size=8192 --expose-gc']) {
      assert.deepEqual(findOwner(provider, 123, () => ({...read(), command:`/opt/node ${flag} /isolated/node_modules/${script}`})), {pid:123, startedAt:'birth'});
    }
    for (const flag of ['--eval', '--require', '--import', '--max-old-space-size=oops']) {
      assert.equal(findOwner(provider, 123, () => ({...read(), command:`/opt/node ${flag} /isolated/node_modules/${script}`})), undefined);
      assert.equal(findOwner(provider, 123, () => ({...read(), command:`/opt/node ${flag}=/isolated/node_modules/${script}`})), undefined);
      assert.equal(findOwner(provider, 123, () => ({...read(), command:`/opt/node ${flag}=/isolated/${provider}`})), undefined);
    }
    assert.equal(findOwner(provider, 123, () => ({...read(), command:`${read().command}.bak`})), undefined);
  }
  const chain = {
    11: {parent:10, startedAt:'runtime birth', command:'node --expose-gc /app/node_modules/@qwen-code/qwen-code/cli.js'},
    10: {parent:9, startedAt:'bootstrap birth', command:'node --expose-gc /app/node_modules/@qwen-code/qwen-code/cli.js'},
    9: {parent:1, startedAt:'launcher birth', command:'node /app/node_modules/@qwen-code/qwen-code/cli-entry.js'},
  };
  assert.deepEqual(findOwner('qwen', 11, pid=>chain[pid]), {pid:11, startedAt:'runtime birth'});
});

test('private atomic files survive concurrent writes and a previous failure', async t => {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), 'loopfwd-hook-test-'));
  t.after(() => fs.rm(base, { recursive: true }));
  const root = path.join(base, 'events');
  await fs.writeFile(root, 'blocked');
  await assert.rejects(saveEvent(root, {}));
  await fs.unlink(root);
  const event = normalize('mistral', { session_id: 'a', hook_event_name: 'post_agent' });
  await Promise.all(Array.from({ length: 12 }, () => saveEvent(root, event)));
  const scope = path.join(root, (await fs.readdir(root))[0]);
  const files = await fs.readdir(scope);
  assert.equal(files.length, 12);
  assert.equal((await fs.stat(root)).mode & 0o777, 0o700);
  for (const file of files) assert.equal((await fs.stat(path.join(scope, file))).mode & 0o777, 0o600);
  const other = normalize('gemini', {session_id:'other',hook_event_name:'BeforeTool'});
  for (let index = 0; index < 257; index++) await saveEvent(root, {...other, observedAt: Date.now()});
  assert.equal((await fs.readdir(scope)).length, 12, 'another provider must not evict this session');
  await fs.symlink(root, path.join(base, 'link'));
  await assert.rejects(saveEvent(path.join(base, 'link'), event));
});

test('bad input never emits a provider decision or nonzero exit', () => {
  const result = spawnSync(process.execPath, [fileURLToPath(new URL('./observe-hook.mjs', import.meta.url)), '--provider', 'mistral'], { input: '{broken', encoding: 'utf8' });
  assert.equal(result.status, 0);
  assert.equal(result.stdout.trim(), '{}');
  assert.equal(result.stderr.includes('broken'), false);
});

async function collectionFixture(t) {
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'loopfwd-hook-collection-'));
  await fs.chmod(root,0o700);
  t.after(()=>fs.rm(root,{recursive:true,force:true}));
  const old=Date.now()-48*60*60*1000;
  const add=async(id,pid,change={})=>{
    const event={...normalize('qwen',{session_id:id,hook_event_name:'MessageDisplay'},undefined,
      pid===null?undefined:{pid,startedAt:'Sun Sep 6 12:00:00 2026'},old),...change};
    const relative=await saveEvent(root,event),file=path.join(root,relative),scope=path.dirname(file);
    await fs.utimes(file,old/1000,old/1000);await fs.utimes(scope,old/1000,old/1000);
    return {event,file,scope};
  };
  return {root,old,add};
}

test('full production buffer admits a new session after confirmed exited old owners',async t=>{
  const f=await collectionFixture(t);
  const child=spawnSync('/usr/bin/true',[],{timeout:1000});
  assert.equal(child.status,0);assert(ownerHasExited(child.pid));
  for(let index=0;index<128;index++) await f.add(`old-${index}`,child.pid);
  const next=normalize('qwen',{session_id:'new',hook_event_name:'MessageDisplay'},undefined,
    {pid:process.pid,startedAt:'current'});
  const file=await saveEvent(f.root,next);
  assert.equal(JSON.parse(await fs.readFile(path.join(f.root,file),'utf8')).sessionID,'new');
  const scopes=(await fs.readdir(f.root)).filter(x=>x!=='.gc');
  assert(scopes.length<=128 && scopes.length>=125);
  assert.equal((await fs.readdir(path.join(f.root,'.gc'))).length,0);
});

test('collection preserves live, unbound, recent, invalid, linked and uncertain records',async t=>{
  const f=await collectionFixture(t);
  const child=spawnSync('/usr/bin/true',[],{timeout:1000});
  const live=await f.add('live',process.pid),unbound=await f.add('unbound',null);
  const recent=await f.add('recent',child.pid,{observedAt:Date.now()});
  const invalid=await f.add('invalid',child.pid);
  await fs.writeFile(invalid.file,'{}');await fs.utimes(invalid.file,f.old/1000,f.old/1000);
  const linked=await f.add('linked',child.pid);
  const linkTarget=path.join(f.root,'user-file');await fs.writeFile(linkTarget,'keep');
  await fs.unlink(linked.file);await fs.symlink(linkTarget,linked.file);
  await fs.utimes(linked.scope,f.old/1000,f.old/1000);
  const unknown=await f.add('unknown',child.pid);
  await fs.writeFile(path.join(unknown.scope,'not-ours.txt'),'keep');
  await fs.utimes(unknown.scope,f.old/1000,f.old/1000);
  assert.equal(await reclaimExpiredScopes(f.root),0);
  for(const item of [live,unbound,recent,invalid,linked,unknown]) assert(await fs.lstat(item.file));
  const valid=await f.add('valid',child.pid);
  assert.equal(await reclaimExpiredScopes(f.root,{probe:()=>false}),0);
  assert(await fs.lstat(valid.file));assert.equal(await fs.readFile(linkTarget,'utf8'),'keep');
});

test('late quarantine writes survive and interrupted cleanup can resume',async t=>{
  const f=await collectionFixture(t);
  const child=spawnSync('/usr/bin/true',[],{timeout:1000});
  const item=await f.add('late',child.pid);
  let target;
  assert.equal(await reclaimExpiredScopes(f.root,{afterQuarantine:async directory=>{
    target=directory;await fs.writeFile(path.join(directory,'late-user-data'),'keep');
  }}),1);
  assert.equal(await fs.readFile(path.join(target,'late-user-data'),'utf8'),'keep');
  assert(await fs.stat(path.join(target,path.basename(item.file))));
  const interrupted=await f.add('interrupted',child.pid);
  let pending;
  await reclaimExpiredScopes(f.root,{afterQuarantine:async directory=>{pending=directory;throw new Error('simulated kill');}});
  assert(await fs.stat(path.join(pending,path.basename(interrupted.file))));
  await reclaimExpiredScopes(f.root);
  await assert.rejects(fs.lstat(pending),{code:'ENOENT'});
  assert.equal(await fs.readFile(path.join(target,'late-user-data'),'utf8'),'keep');
});

test('concurrent collectors do not evict an active owner or follow a gc symlink',async t=>{
  const f=await collectionFixture(t);
  const child=spawnSync('/usr/bin/true',[],{timeout:1000});
  const live=await f.add('live',process.pid);
  for(let i=0;i<6;i++) await f.add(`expired-${i}`,child.pid);
  await Promise.all([reclaimExpiredScopes(f.root),reclaimExpiredScopes(f.root)]);
  assert(await fs.stat(live.file));
  const second=await collectionFixture(t),target=path.join(second.root,'untouched');
  await fs.mkdir(target);await fs.writeFile(path.join(target,'keep'),'keep');
  const old=await second.add('expired',child.pid);
  await fs.symlink(target,path.join(second.root,'.gc'));
  assert.equal(await reclaimExpiredScopes(second.root),0);
  assert(await fs.stat(old.file));assert.equal(await fs.readFile(path.join(target,'keep'),'utf8'),'keep');
});

test('quarantine overflow still recovers interrupted entries instead of wedging',async t=>{
  const f=await collectionFixture(t);
  const child=spawnSync('/usr/bin/true',[],{timeout:1000});
  const old=await f.add('overflow',child.pid),gc=path.join(f.root,'.gc');
  await fs.mkdir(gc,{mode:0o700});
  for(let index=0;index<129;index++) {
    // An interrupted rmdir may leave an empty, private, already-aged directory.
    const directory=path.join(gc,`${path.basename(old.scope)}~${randomUUID()}`);
    await fs.mkdir(directory,{mode:0o700});await fs.utimes(directory,f.old/1000,f.old/1000);
  }
  await reclaimExpiredScopes(f.root);
  assert.equal((await fs.readdir(gc)).length,125);
  assert(await fs.stat(old.file),'overflow must not allow new quarantine entries yet');
});
