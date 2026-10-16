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
      queue.push(response(remote),response({version:3}));await d.retry();
      assert.equal(d.version,3);assert.equal(d.dirty,false);
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
end
