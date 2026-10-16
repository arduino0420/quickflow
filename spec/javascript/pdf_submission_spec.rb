require "spec_helper"
require "open3"

RSpec.describe "Handwritten PDF submission lifecycle" do
  it "locks input, flushes latest ink, reconciles lost responses and preserves ink on failures" do
    script = <<~JS
      const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
      const source=fs.readFileSync(process.argv[1],'utf8').replace(/^import .*$/gm,'').replace('export default class','class Preview');
      let generationError=false,generated=0;
      const locations=[];
      const Preview=vm.runInNewContext(source+';Preview',{
        Controller:class{},window:{location:{assign:url=>locations.push(url)}},
        Blob,FormData,AbortSignal,document:{querySelector:()=>({content:'csrf'})},
        snapshotPages:states=>structuredClone(states),generateAnswerPdf:async({pages})=>{
          generated++;assert.deepEqual(pages,[{ink:'latest'}]);if(generationError)throw Error('PNG failed');return new Uint8Array([37,80,68,70]);
        }
      });
      function editor() {
        const c=new Preview();Object.assign(c,{active:true,session:Symbol(),pagesReady:true,exporting:false,
          pdf:{getData:async()=>new Uint8Array([1])},pageStates:[{ink:'latest'}],toolTargets:[{}],sizeTargets:[{}],
          submitTarget:{},submitStatusTarget:{setAttribute(){}},draftEditable:true,
          draft:{ready:true,allowed:true,blocked:false,dirty:true,version:0,flush:async()=>{assert(c.exporting);c.draft.dirty=false;return 7},stop(){this.stopped=true}}});
        c.finishInput=()=>{};return c;
      }
      (async()=>{
        const c=editor(),calls=[];let release;
        c.submissionState=async options=>{
          calls.push(options||{});
          if(!options)return {submitted:false};
          assert(c.submitTarget.disabled);assert(c.toolTargets[0].disabled);
          assert.equal(options.body.get('draft_version'),'7');
          assert.equal(options.body.get('submission[answer_file]').type,'application/pdf');
          return new Promise(r=>release=r);
        };
        const first=c.submitAnswer();await new Promise(r=>setImmediate(r));
        await c.submitAnswer();assert.equal(calls.length,2,'double click cannot upload twice');
        release({submitted:true,location:'/result'});await first;
        assert.deepEqual(locations,['/result']);assert(c.draft.stopped);assert.equal(c.draftEditable,false);
        const fail=editor();generationError=true;let posts=0;
        fail.submissionState=async options=>{if(options)posts++;return {submitted:false}};
        await fail.submitAnswer();assert.equal(posts,0);assert.equal(fail.pageStates[0].ink,'latest');
        assert.equal(fail.submitTarget.disabled,false);assert.equal(fail.draft.allowed,true);
        generationError=false;
        const unsaved=editor();unsaved.draft.flush=async()=>{throw Error('save failed')};
        unsaved.submissionState=fail.submissionState;await unsaved.submitAnswer();assert.equal(posts,0);assert(unsaved.draft.dirty);
        const conflict=editor();conflict.submissionState=async options=>{
          if(options){const e=Error('conflict');e.code=409;throw e}return {submitted:false};
        };
        await conflict.submitAnswer();assert(conflict.draft.blocked);assert.equal(conflict.draftEditable,false);
        assert.equal(conflict.pageStates[0].ink,'latest');
        const other=editor();other.submissionState=async()=>({submitted:true,location:'/other'});
        await other.submitAnswer();assert(other.draft.dirty);assert(other.draft.blocked);
        assert.deepEqual(locations,['/result'],'another tab must not discard local unsaved ink');
        const lost=editor();let gets=0;
        lost.submissionState=async options=>{if(options)throw TypeError('lost response');return ++gets===1?{submitted:false}:{submitted:true,location:'/recovered'}};
        await lost.submitAnswer();assert.equal(gets,2);assert.deepEqual(locations,['/result','/recovered']);
        assert.equal(lost.pageStates[0].ink,'latest');
      })().catch(e=>{console.error(e);process.exitCode=1});
    JS
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
