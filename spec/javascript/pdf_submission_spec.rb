require "spec_helper"
require "open3"

RSpec.describe "Handwritten PDF submission lifecycle" do
  it "locks input, snapshots latest ink, reconciles lost responses and preserves ink on failures" do
    script = <<~JS
      const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
      const source=fs.readFileSync(process.argv[1],'utf8').replace(/^import .*$/gm,'').replace('export default class','class Preview');
      let generationError=false,generated=0;
      const locations=[];
      const Preview=vm.runInNewContext(source+';Preview',{
        Controller:class{},window:{location:{assign:url=>locations.push(url)}},
        Blob,FormData,AbortSignal,crypto:require("node:crypto").webcrypto,document:{querySelector:()=>({content:'csrf'})},
        snapshotPages:states=>structuredClone(states),generateAnswerPdf:async({pages})=>{
          generated++;assert.deepEqual(pages,[{ink:'latest'}]);if(generationError)throw Error('PNG failed');return new Uint8Array([37,80,68,70]);
        }
      });
      function editor() {
        const c=new Preview();Object.assign(c,{confirmation:{ask:async()=>true,cancel(){},destroy(){}},active:true,session:Symbol(),pagesReady:true,exporting:false,
          pdf:{getData:async()=>new Uint8Array([1])},pageStates:[{ink:'latest'}],toolTargets:[{}],sizeTargets:[{}],
          submitTarget:{},submitStatusTarget:{setAttribute(){}},draftEditable:true,
          draft:{ready:true,allowed:true,blocked:false,dirty:true,version:0,revision:1,prepareSubmission:async()=>{assert(c.exporting);return 7},finishSubmission(){},stop(){this.stopped=true}}});
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
        release({submitted:true,submission_token:c.submissionAttempt.token,location:'/result'});await first;
        assert.deepEqual(locations,['/result']);assert.equal(c.submissionConfirmed,true);assert(c.draft.stopped);assert.equal(c.draftEditable,false);
        const fail=editor();generationError=true;let posts=0;
        fail.submissionState=async options=>{if(options)posts++;return {submitted:false}};
        await fail.submitAnswer();assert.equal(posts,0);assert.equal(fail.pageStates[0].ink,'latest');
        assert.equal(fail.submitTarget.disabled,false);assert.equal(fail.draft.allowed,true);
        generationError=false;
        const unsaved=editor();unsaved.draft.prepareSubmission=async()=>{throw Error('save pending')};
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
        lost.submissionState=async options=>{if(options)throw TypeError('lost response');return ++gets===1?{submitted:false}:{submitted:true,submission_token:lost.submissionAttempt.token,location:'/recovered'}};
        await lost.submitAnswer();assert.equal(gets,2);assert.deepEqual(locations,['/result','/recovered']);
        assert.equal(lost.pageStates[0].ink,'latest');
        const mismatch=editor();let wrongGets=0;
        mismatch.submissionState=async options=>{
          if(options)throw TypeError('lost response');
          return ++wrongGets===1?{submitted:false}:{submitted:true,submission_token:require('node:crypto').randomUUID(),location:'/wrong'};
        };
        await mismatch.submitAnswer();assert(mismatch.draft.blocked);assert.notEqual(mismatch.submissionConfirmed,true);
        assert.equal(mismatch.pageStates[0].ink,'latest');
        assert.deepEqual(locations,['/result','/recovered'],'a different attempt must never be accepted');
      })().catch(e=>{console.error(e);process.exitCode=1});
    JS
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it "requires a single positive confirmation before any submission work and rejects stale intent" do
    script = <<~JS
      const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
      const source=fs.readFileSync(process.argv[1],'utf8').replace(/^import .*$/gm,'').replace('export default class','class Preview');
      const Preview=vm.runInNewContext(source+';Preview',{Controller:class{}});
      function editor(){
        const c=new Preview();let resolve,asks=0,work=0,ends=0;
        Object.assign(c,{active:true,session:Symbol(),pagesReady:true,pdf:{},submitTarget:{},submitStatusTarget:{},
          draft:{ready:true,allowed:true,blocked:false},confirmation:{ask:()=>{asks++;return new Promise(r=>resolve=r)}},
          finishInput:()=>ends++,performSubmission:async()=>{work++}});
        return {c,answer:value=>resolve(value),counts:()=>({asks,work,ends})};
      }
      (async()=>{
        const no=editor(),pending=no.c.submitAnswer();
        await no.c.submitAnswer();assert.deepEqual(no.counts(),{asks:1,work:0,ends:1});
        assert(no.c.submitTarget.disabled);no.answer(false);await pending;
        assert.equal(no.counts().work,0);assert.equal(no.c.submitTarget.disabled,false);
        const yes=no.c.submitAnswer();no.answer(true);await yes;assert.equal(no.counts().work,1);
        const stale=editor(),old=stale.c.submitAnswer();stale.c.session=Symbol();stale.answer(true);await old;
        assert.equal(stale.counts().work,0);
        const gone=editor(),removed=gone.c.submitAnswer();gone.c.active=false;gone.answer(true);await removed;
        assert.equal(gone.counts().work,0);
        const blocked=editor(),waiting=blocked.c.submitAnswer();blocked.c.draft.blocked=true;
        blocked.c.performSubmission=Preview.prototype.performSubmission;
        blocked.c.submissionState=()=>{throw Error('blocked draft must not make a request')};
        blocked.answer(true);await waiting;assert.equal(blocked.counts().work,0);
      })().catch(e=>{console.error(e);process.exitCode=1});
    JS
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it "discards the removed dialog so a reconnected controller can ask again" do
    script = <<~JS
      const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
      const source=fs.readFileSync(process.argv[1],'utf8').replace(/^import .*$/gm,'').replace('export default class','class Preview');
      let created=0,destroyed=0,submitted=0;
      const Preview=vm.runInNewContext(source+';Preview',{
        Controller:class{},window:{clearTimeout(){}},document:{documentElement:{removeAttribute(){},setAttribute(){}}},
        SubmissionConfirmation:class{constructor(){created++}async ask(){return true}}
      });
      (async()=>{
        const c=new Preview();Object.assign(c,{active:true,session:Symbol(),pageStates:[],previousTurboSetting:null,
          confirmation:{destroy(){destroyed++}},draft:{stop(){},ready:true,allowed:true,blocked:false},
          finishInput(){},stopInputDiagnostics(){},submitTarget:{},submitStatusTarget:{}});
        c.disconnect();assert.equal(destroyed,1);assert.equal(c.confirmation,null);assert.equal(c.active,false);
        c.active=true;c.session=Symbol();c.pagesReady=true;c.pdf={};
        c.performSubmission=async()=>submitted++;
        await c.submitAnswer();assert.equal(created,1);assert.equal(submitted,1);
      })().catch(e=>{console.error(e);process.exitCode=1});
    JS
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it "keeps ink when both submission and reconciliation lose connectivity, then retries safely" do
    script = <<~JS
      const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
      const source=fs.readFileSync(process.argv[1],'utf8').replace(/^import .*$/gm,'').replace('export default class','class Preview');
      const locations=[];
      const Preview=vm.runInNewContext(source+';Preview',{
        Controller:class{},window:{location:{assign:url=>locations.push(url)}},
        Blob,FormData,AbortSignal,crypto:require("node:crypto").webcrypto,document:{querySelector:()=>({content:'csrf'})},
        snapshotPages:states=>structuredClone(states),generateAnswerPdf:async()=>new Uint8Array([37,80,68,70])
      });
      const c=new Preview();let posts=0,checks=0,flushes=0;
      Object.assign(c,{confirmation:{ask:async()=>true,cancel(){},destroy(){}},active:true,session:Symbol(),pagesReady:true,exporting:false,
        pdf:{getData:async()=>new Uint8Array([1])},pageStates:[{ink:'latest'}],toolTargets:[{}],sizeTargets:[{}],
        submitTarget:{},submitStatusTarget:{setAttribute(){}},draftEditable:true,
        draft:{ready:true,allowed:true,blocked:false,dirty:true,version:0,revision:1,
          prepareSubmission:async()=>{flushes++;return 7},finishSubmission(){},stop(){this.stopped=true}}});
      c.finishInput=()=>{};
      c.submissionState=async options=>{
        if(options){posts++;throw TypeError('connection lost')}
        checks++;
        if(checks===2)throw TypeError('status unavailable');
        return {submitted:false};
      };
      (async()=>{
        await c.submitAnswer();
        assert.equal(posts,1);assert.equal(checks,2);assert.equal(locations.length,0);
        assert.equal(c.pageStates[0].ink,'latest');assert.equal(c.draft.dirty,true);
        assert.equal(c.draft.allowed,true);assert.equal(c.submitTarget.disabled,false);
        assert.equal(c.submitStatusTarget.textContent.includes('提出できませんでした'),true);
        c.submissionState=async options=>{
          if(options){posts++;assert.equal(options.body.get('submission_token'),c.submissionAttempt.token);return {submitted:true,submission_token:c.submissionAttempt.token,location:'/result'}}
          checks++;return {submitted:false};
        };
        await c.submitAnswer();
        assert.equal(checks,3);assert.equal(posts,2);assert.equal(flushes,2);
        assert.deepEqual(locations,['/result']);assert.equal(c.draft.stopped,true);
      })().catch(error=>{console.error(error);process.exitCode=1});
    JS
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
