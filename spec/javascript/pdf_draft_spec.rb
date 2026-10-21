require "spec_helper"
require "open3"

RSpec.describe "PDF draft autosave lifecycle" do
  it "debounces, serializes saves, snapshots edits, retries lost responses and never merges conflicts" do
    script = <<~JS
      import fs from 'node:fs';import assert from 'node:assert/strict';
      const {default:PdfDraft}=await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(process.argv[1],'utf8')).toString('base64'));
      globalThis.document={querySelector:()=>({content:'csrf-test'})};
      const tick=()=>new Promise(r=>setTimeout(r,5));
      const queue=[], calls=[], messages=[];let restored,editable, value={format_version:1,pages:[]};
      const fetch=async(url,options)=>{calls.push(options);const next=queue.shift();if(!next)throw Error('missing response');return await next;};
      const response=(draft=null,editable=true)=>({ok:true,json:async()=>({draft,editable})});
      const d=new PdfDraft({url:'/draft',context:'signed',read:()=>value,restore:data=>{restored=data},
        status:(...args)=>messages.push(args),editable:v=>{editable=v},fetch,delay:10});
      queue.push(response());await d.start();assert.equal(editable,true);assert.equal(d.dirty,false);
      let resolve;queue.push(new Promise(r=>resolve=r));
      d.changed();d.changed();d.changed();await new Promise(r=>setTimeout(r,20));
      assert.equal(calls.length,2);assert.equal(d.saving,true);
      assert.equal(calls[1].headers['X-CSRF-Token'],'csrf-test');
      assert.equal(calls[1].headers['X-Draft-Context'],'signed');
      value.pages.push({page_number:1,operations:[]});d.changed();
      assert.deepEqual(JSON.parse(calls[1].body).draft_data.pages,[],'in-flight snapshot cannot change');
      resolve(response({version:0}));await tick();assert.equal(d.dirty,true);
      queue.push(response({version:1}));await new Promise(r=>setTimeout(r,25));
      assert.equal(calls.length,3);assert.equal(d.dirty,false);assert.equal(d.version,1);
      assert.equal(messages.at(-1)[0],'保存済み');
      // Fail after the server might have committed, preserving local edits.
      value.pages[0].operations.push({id:1,points:[[1,2]],tool:'pen',width:1.2,color:'#000000'});
      d.changed();queue.push(Promise.resolve().then(()=>({ok:false,status:503})));await d.save();
      assert.equal(d.dirty,true);assert.equal(d.failed,true);
      // JSONB object key order differs; canonical comparison must still reconcile.
      const remote={version:2,pages:structuredClone(value.pages),format_version:1};
      remote.pages[0].operations[0]={color:'#000000',width:1.2,tool:'pen',points:[[1,2]],id:1};
      const beforeRetry=calls.length;
      queue.push(response(remote));await d.retry();
      assert.equal(calls.length,beforeRetry+1,'confirmed identical snapshot needs GET only');
      assert.equal(d.version,2);assert.equal(d.dirty,false);
      d.changed();queue.push({ok:false,status:409});await d.save();
      assert.equal(d.blocked,true);assert.equal(editable,false);assert.equal(d.dirty,true);
      const before=calls.length;await d.retry();assert.equal(calls.length,before);
      d.stop();assert(d.abort.signal.aborted);
      // Restoration failures do not enable editing, and can be retried.
      const q=[{ok:false,status:503},response({version:9,pages:[],format_version:1})];
      const r=new PdfDraft({url:'/draft',context:'x',read:()=>value,restore:v=>restored=v,status:()=>{},editable:v=>editable=v,
        fetch:async()=>q.shift(),delay:10});
      await r.start();assert.equal(r.ready,undefined);assert.equal(r.failed,true);
      await r.retry();assert.equal(r.ready,true);assert.equal(restored.version,9);
      r.changed();q.push(response({version:9}));r.stop();await new Promise(r=>setTimeout(r,20));assert.equal(q.length,1);
    JS
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
  it "flushes a pending save and its newer strokes before returning the final version" do
    script = <<~JS
      import fs from 'node:fs';import assert from 'node:assert/strict';
      const {default:PdfDraft}=await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(process.argv[1],'utf8')).toString('base64'));
      globalThis.document={querySelector:()=>({content:'csrf'})};
      let release,version=-1,puts=0;
      const d=new PdfDraft({url:'/draft',context:'ctx',read:()=>({format_version:1,pages:[]}),restore:()=>{},status:()=>{},editable:()=>{},delay:60000,
        fetch:async(url,o)=>{if(o.method==='GET')return {ok:true,json:async()=>({draft:null,editable:true})};puts++;
          if(puts===1)await new Promise(r=>release=r);
          return {ok:true,json:async()=>({draft:{version:++version}})};}});
      await d.start();d.changed();const save=d.save();d.changed();const flush=d.flush();
      release();await save;assert.equal(await flush,1);assert.equal(puts,2);assert.equal(d.dirty,false);
      d.failed=true;await assert.rejects(()=>d.flush());d.stop();
    JS
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
  it "waits for an in-flight save without requiring new ink to autosave before submission" do
    script = <<~JS
      import fs from 'node:fs';import assert from 'node:assert/strict';
      const {default:PdfDraft}=await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(process.argv[1],'utf8')).toString('base64'));
      globalThis.document={querySelector:()=>({content:'csrf'})};
      let release,puts=0,gets=0;
      const d=new PdfDraft({url:'/draft',context:'signed',read:()=>({format_version:1,pages:[]}),
        restore:()=>{},status:()=>{},editable:()=>{},delay:60000,fetch:async(_url,options)=>{
          if(options.method==='GET'){gets++;return {ok:true,json:async()=>({draft:null,editable:true})};}
          puts++;await new Promise(resolve=>release=resolve);
          return {ok:true,json:async()=>({draft:{version:0}})};
        }});
      await d.start();d.changed();const save=d.save();
      await new Promise(resolve=>setTimeout(resolve,0));
      d.changed();const prepared=d.prepareSubmission();
      await new Promise(resolve=>setTimeout(resolve,5));
      assert.equal(d.submitting,true);assert.equal(d.saving,true);
      release();await save;assert.equal(await prepared,0);
      assert.equal(d.dirty,true,'newer visible ink remains outside the saved snapshot');
      assert.equal(puts,1,'preparing submission must not upload the newer giant draft');
      assert.equal(gets,1);
      d.finishSubmission();d.stop();
    JS
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
  it "reconciles an uncertain save only when the remote snapshot is identical" do
    script = <<~JS
      import fs from 'node:fs';import assert from 'node:assert/strict';
      const {default:PdfDraft}=await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(process.argv[1],'utf8')).toString('base64'));
      globalThis.document={querySelector:()=>({content:'csrf'})};
      for(const matches of [true,false]) {
        const value={format_version:1,pages:[{page_number:1,operations:[]}]};
        let gets=0;
        const d=new PdfDraft({url:'/draft',context:'signed',read:()=>value,restore:()=>{},status:()=>{},
          editable:()=>{},delay:60000,fetch:async(_url,options)=>{
            if(options.method==='PUT') return {ok:false,status:503,json:async()=>({})};
            gets++;
            return {ok:true,json:async()=>gets===1?{draft:null,editable:true}:{
              draft:{version:0,format_version:1,pages:matches?value.pages:[]},editable:true}};
          }});
        await d.start();d.changed();await d.save();
        if(matches) {
          assert.equal(await d.prepareSubmission(),0);
          assert.equal(d.version,0);assert.equal(d.dirty,false);
          d.finishSubmission();
        } else await assert.rejects(()=>d.prepareSubmission(),{code:409});
        d.stop();
      }
    JS
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
  it "keeps writing and submission available after capacity rejection while blocking unsafe data" do
    script = <<~JS
      import fs from 'node:fs';import assert from 'node:assert/strict';
      const {default:PdfDraft}=await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(process.argv[1],'utf8')).toString('base64'));
      globalThis.document={querySelector:()=>({content:'csrf'})};
      const cases=[
        [413,'request_too_large','送信する手書きデータの容量'],
        [422,'draft_bytes_limit','手書きデータの容量'],
        [422,'draft_pages_limit','ページ数'],
        [422,'draft_operations_limit','線の数'],
        [422,'draft_points_limit','細かな動きの記録'],
        [422,'invalid_data','正しく読み取れなかった'],
        [422,'csrf_failed','ログインの有効期限'],
        [422,'<secret student answer>','保存の要求を受け付けられませんでした'],
        [422,null,'保存の要求を受け付けられませんでした'],
        [400,'invalid_json','正しく送信'],[415,'unsupported_content_type','正しく送信']
      ];
      for(const [status,reason,expected] of cases){
        const value={format_version:1,pages:[{page_number:1,operations:[{id:1,tool:'pen',width:1.2,color:'#000000',points:[[1,2],[1.01,2.01]]}]}]};
        const original=JSON.stringify(value),messages=[];let calls=0,editable;
        const d=new PdfDraft({url:'/draft',context:'ctx',read:()=>value,restore:()=>assert.fail('must not restore over unsaved ink'),
          status:(...args)=>messages.push(args),editable:v=>editable=v,delay:60000,
          fetch:async()=>{calls++;return calls===1?{ok:true,json:async()=>({draft:null,editable:true})}:
            {ok:false,status,json:async()=>{if(reason===null)throw Error('HTML response');return {error:reason,details:'private answer'};}};}});
        await d.start();d.changed();await d.save();
        const capacity=status===413 || (status===422 && !!reason?.startsWith('draft_'));
        assert.equal(d.blocked,!capacity);assert.equal(d.saveBlocked,capacity);
        assert.equal(d.failed,true);assert.equal(editable,capacity);assert.equal(d.dirty,true);
        assert.equal(d.version,null);assert.equal(JSON.stringify(value),original);assert.equal(JSON.stringify(d.lastAttempt),original);
        const message=messages.at(-1)[0];assert(message.includes(expected),message);
        assert(message.includes(reason==='csrf_failed'?'画面を閉じず':'再読み込み'));
        assert(!message.includes('secret'));assert(!message.includes('private'));assert.notEqual(messages.at(-1)[1],true);
        const before=calls;d.changed();await d.retry();await d.save();
        if(capacity) {
          assert.equal(await d.prepareSubmission(),null);
          d.finishSubmission();
          assert(message.includes('手書きと提出は続けられます'));
        } else await assert.rejects(()=>d.prepareSubmission());
        assert.equal(calls,before,'no identical retry or submission after permanent rejection');d.stop();
      }
      // A server-provided limit code on a temporary response must not disable retry.
      let calls=0;const messages=[];
      const d=new PdfDraft({url:'/draft',context:'ctx',read:()=>({format_version:1,pages:[]}),restore:()=>{},status:(...args)=>messages.push(args),editable:()=>{},delay:60000,
        fetch:async()=>++calls===1?{ok:true,json:async()=>({draft:null,editable:true})}:{ok:false,status:503,json:async()=>({error:'draft_points_limit'})}});
      await d.start();d.changed();await d.save();assert.equal(d.blocked,false);assert.equal(messages.at(-1)[1],true);d.stop();
    JS
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it "keeps transient failures retryable but blocks authentication and version conflicts" do
    script = <<~JS
      import fs from 'node:fs';import assert from 'node:assert/strict';
      const {default:PdfDraft}=await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(process.argv[1],'utf8')).toString('base64'));
      globalThis.document={querySelector:()=>({content:'csrf'})};
      for(const status of [401,403,409,429,503]) {
        let editable=true,calls=0;
        const d=new PdfDraft({url:'/draft',context:'signed',read:()=>({format_version:1,pages:[]}),
          restore:()=>{},status:()=>{},editable:value=>editable=value,delay:60000,
          fetch:async()=>++calls===1?{ok:true,json:async()=>({draft:null,editable:true})}:
            {ok:false,status,json:async()=>({error:'version_conflict'})}});
        await d.start();d.changed();await d.save();
        assert.equal(d.blocked,![429,503].includes(status));
        assert.equal(editable,[429,503].includes(status));
        if(![429,503].includes(status)) await assert.rejects(()=>d.prepareSubmission());
        d.stop();
      }
    JS
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
  it "checkpoints continuous completed strokes without overlapping saves or debouncing forever" do
    script = <<~JS
      import fs from 'node:fs';import assert from 'node:assert/strict';
      const {default:PdfDraft}=await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(process.argv[1],'utf8')).toString('base64'));
      globalThis.document={querySelector:()=>({content:'csrf'})};
      let now=0,serial=0,release,puts=0;
      const timers=new Map();Date.now=()=>now;
      globalThis.setTimeout=(callback,delay)=>{const id=++serial;timers.set(id,{callback,at:now+delay});return id};
      globalThis.clearTimeout=id=>timers.delete(id);
      const d=new PdfDraft({url:'/draft',context:'signed',delay:25,maxWait:100,
        read:()=>({format_version:1,pages:[]}),restore:()=>{},status:()=>{},editable:()=>{},fetch:async(_url,o)=>{
          if(o.method==='GET')return {ok:true,json:async()=>({draft:null,editable:true})};
          puts++;assert.equal(o.headers['X-Draft-Response'],'acknowledgment');
          await new Promise(resolve=>release=resolve);
          return {ok:true,json:async()=>({draft:{version:puts-1}})};
        }});
      await d.start();d.changed();assert.equal(timers.get(d.timer).at,25);
      for(now=20;now<=80;now+=20){d.changed();assert(timers.get(d.timer).at<=100)}
      now=99;d.changed();assert.equal(timers.get(d.timer).at,100);
      now=100;const entry=timers.get(d.timer);const saving=entry.callback();
      assert.equal(puts,1);d.changed();await d.save();assert.equal(puts,1);
      release();await saving;
      assert.equal(d.dirty,true);assert.equal(d.version,0);
      assert(timers.get(d.timer).at<=200,'edits during saving retain a next checkpoint');
      d.stop();
    JS
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
  it "retries newer ink after a lost save without resending an already confirmed snapshot" do
    script = <<~JS
      import fs from 'node:fs';import assert from 'node:assert/strict';
      const {default:PdfDraft}=await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(process.argv[1],'utf8')).toString('base64'));
      globalThis.document={querySelector:()=>({content:'csrf'})};
      let remote=null,puts=0;
      const data={format_version:1,pages:[{page_number:1,operations:[]}]};
      const d=new PdfDraft({url:'/draft',context:'signed',read:()=>data,restore:()=>{},status:()=>{},editable:()=>{},delay:60000,
        fetch:async(_url,o)=>{
          if(o.method==='GET')return {ok:true,json:async()=>({draft:remote,editable:true})};
          puts++;const body=JSON.parse(o.body);
          if(puts===1){remote={...structuredClone(body.draft_data),version:0};throw TypeError('lost response')}
          assert.equal(body.expected_version,0);assert.equal(body.draft_data.pages[0].operations.length,1);
          remote={...body.draft_data,version:1};return {ok:true,json:async()=>({draft:{version:1}})};
        }});
      await d.start();d.changed();await d.save();
      data.pages[0].operations.push({id:1,tool:'pen',color:'#000000',width:1.2,points:[[1.123456789012345,2]]});d.changed();
      await d.retry();assert.equal(puts,2);assert.equal(d.version,1);assert.equal(d.dirty,false);
      assert.deepEqual(remote.pages,data.pages);d.stop();
    JS
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
  it "serializes initial restoration retries and ignores restoration after disposal" do
    script = <<~JS
      import fs from 'node:fs';import assert from 'node:assert/strict';
      const {default:PdfDraft}=await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(process.argv[1],'utf8')).toString('base64'));
      globalThis.document={querySelector:()=>({content:'csrf'})};
      let calls=0,restores=0,release;
      const options={url:'/draft',context:'signed',read:()=>({}),restore:()=>restores++,status:()=>{},editable:()=>{},
        fetch:async()=>{calls++;return new Promise(resolve=>release=resolve)}};
      const d=new PdfDraft(options);const initial=d.start();
      await d.start();await d.retry();assert.equal(calls,1,'initial retries cannot overlap GETs');
      release({ok:true,json:async()=>({draft:{version:0},editable:true})});await initial;
      assert.equal(restores,1);assert.equal(d.ready,true);assert.equal(d.starting,false);
      await d.start();assert.equal(calls,1);d.stop();
      const gone=new PdfDraft(options);const pending=gone.start();gone.stop();
      release({ok:true,json:async()=>({draft:{version:0},editable:true})});await pending;
      assert.equal(restores,1,'a response after leaving must not restore ink');assert.equal(gone.ready,undefined);
    JS
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
  it "appends only exact prefixes, reconciles lost append responses and falls back for changed history" do
    script = <<~JS
      import fs from 'node:fs';import assert from 'node:assert/strict';
      const {default:PdfDraft}=await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(process.argv[1],'utf8')).toString('base64'));
      globalThis.document={querySelector:()=>({content:'csrf'})};
      const stroke=id=>({id,tool:id===2?'eraser':'pen',color:'#000000',width:id===2?8:1.2,points:[[1.123456789012345,2],[3,4]]});
      let remote={format_version:1,pages:[{page_number:1,operations:[stroke(1)]}],version:0},puts=0;
      let data={format_version:1,pages:structuredClone(remote.pages)},lose=true;
      const d=new PdfDraft({url:'/draft',context:'signed',read:()=>data,restore:()=>{},status:()=>{},editable:()=>{},delay:60000,
        fetch:async(_url,o)=>{
          if(o.method==='GET')return {ok:true,json:async()=>({draft:structuredClone(remote),editable:true,append_supported:true})};
          puts++;const body=JSON.parse(o.body);assert.equal(body.expected_version,remote.version);
          if(body.append_data){assert(!body.draft_data);assert.equal(body.append_data.pages[0].operations.length,1);
            remote.pages[0].operations.push(...body.append_data.pages[0].operations);
          }else remote.pages=body.draft_data.pages;
          remote.version++;
          if(lose){lose=false;throw TypeError('response lost')}
          return {ok:true,json:async()=>({draft:{version:remote.version}})};
        }});
      await d.start();data.pages[0].operations.push(stroke(2));d.changed();await d.save();
      assert.equal(d.failed,true);assert.equal(d.version,0);await d.retry();
      assert.equal(puts,1,'confirmed append must not be sent twice');assert.equal(d.version,1);assert.equal(d.dirty,false);
      data.pages[0].operations.push(stroke(3));d.changed();await d.save();assert.equal(puts,2);
      assert.deepEqual(remote.pages,data.pages,'pen, eraser and precise coordinates survive exactly');
      for(const alter of [
        v=>v.pages[0].operations[0].points[0][0]+=1e-12,
        v=>v.pages[0].operations.reverse(),v=>v.pages[0].operations.pop(),
        v=>v.pages[0].operations[0].extra='invalid',v=>v.pages[0].operations[0].points[0].push(7),
        v=>v.pages[0].extra='invalid',v=>v.extra='invalid'
      ]){const changed=structuredClone(data);alter(changed);assert.equal(d.appendData(changed),null,'changed or invalid history must use full validation')}
      data.pages[0].operations[0].points[0][0]+=1e-12;d.changed();await d.save();
      assert.deepEqual(remote.pages,data.pages);assert.equal(puts,3);d.stop();
      const old=new PdfDraft({url:'/draft',context:'x',read:()=>data,restore:()=>{},status:()=>{},editable:()=>{},
        fetch:async()=>({ok:true,json:async()=>({draft:remote,editable:true})})});
      await old.start();assert.equal(old.appendData(data),null,'old servers do not negotiate append');old.stop();
    JS
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
