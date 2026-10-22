require "spec_helper"
require "open3"

RSpec.describe "PDF recovery after authentication expires" do
  it "keeps ink and stops retries until a matching draft is explicitly resumed" do
    script = <<~JS
      import fs from 'node:fs';import assert from 'node:assert/strict';
      const {default:PdfDraft}=await import('data:text/javascript;base64,'+Buffer.from(fs.readFileSync(process.argv[1],'utf8')).toString('base64'));
      let csrf='old-token',expired=0,puts=0,remote=null;
      globalThis.document={querySelector:()=>({content:csrf})};
      const ink={format_version:1,pages:[{page_number:1,operations:[{id:1,tool:'pen',width:1.2,color:'#000000',points:[[1,2]]}]}]};
      const draft=new PdfDraft({url:'/draft',context:'signed',read:()=>ink,restore:()=>assert.fail('no remote overwrite'),
        status:()=>{},editable:()=>{},expired:()=>expired++,delay:60000,
        fetch:async (_url,options)=>{
          if(options.method==='GET')return {ok:true,json:async()=>({draft:remote,editable:true})};
          puts++;
          if(puts===1)return {ok:false,status:401,json:async()=>({})};
          assert.equal(options.headers['X-CSRF-Token'],'fresh-token');
          assert.equal(JSON.parse(options.body).expected_version,null);
          return {ok:true,json:async()=>({draft:{version:0}})};
        }});
      await draft.start();draft.changed();await draft.save();
      assert.equal(expired,1);assert.equal(draft.blocked,true);assert.equal(draft.dirty,true);
      await draft.retry();await draft.save();assert.equal(puts,1,'401 cannot loop');
      assert.equal(draft.resume({version:8,format_version:1,pages:[{page_number:1,operations:[]}]}),false);
      assert.equal(draft.blocked,true);assert.equal(draft.dirty,true);
      csrf='fresh-token';assert.equal(draft.resume(null),true);
      assert.equal(draft.dirty,true);await draft.save();assert.equal(draft.dirty,false);assert.equal(puts,2);
      draft.stop();

      let release,committed={version:1,format_version:1,pages:structuredClone(ink.pages)};
      const recovering=new PdfDraft({url:'/draft',context:'signed',read:()=>ink,restore:()=>{},status:()=>{},editable:()=>{},
        delay:60000,fetch:async (_url,options)=>options.method==='GET'?{ok:true,json:async()=>({draft:remote,editable:true})}:
          new Promise(resolve=>release=()=>resolve({ok:false,status:401,json:async()=>({})}))});
      await recovering.start();recovering.changed();const inFlight=recovering.save();
      await new Promise(resolve=>setTimeout(resolve,0));
      ink.pages[0].operations.push({id:2,tool:'pen',width:1.2,color:'#000000',points:[[3,4]]});recovering.changed();
      assert.equal(recovering.resume(committed),false,'cannot resume while save is in flight');
      release();await inFlight;
      assert.equal(recovering.resume(committed),true,'identical committed snapshot reconciles lost acknowledgment');
      assert.equal(recovering.version,1);assert.equal(recovering.dirty,true,'newer local stroke remains unsaved');
      assert.equal(ink.pages[0].operations.length,2);recovering.stop();
    JS
    stdout, stderr, status = Open3.capture3("node", "--input-type=module", "-e", script,
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
