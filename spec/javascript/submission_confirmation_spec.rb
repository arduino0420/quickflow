require "spec_helper"
require "open3"

RSpec.describe "Legacy submission confirmation lifecycle" do
  it "gates state reads on yes and invalidates a preflight after pagehide, disconnect or changed input" do
    script = <<~JS
      const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
      const source=fs.readFileSync(process.argv[1],'utf8').replace(/^import .*$/gm,'').replace('export default class','class Legacy');
      let requests=0,release,currentContext='signed',parsedContext='signed';
      const Legacy=vm.runInNewContext(source+';Legacy',{
        Controller:class{},Symbol,URL,AbortController,setTimeout,clearTimeout,
        window:{location:{href:'https://example.test/assignments/1',origin:'https://example.test'}},
        fetch:()=>{requests++;return new Promise(r=>release=()=>r({ok:true,text:async()=>''}))},
        DOMParser:class{parseFromString(){return{querySelector:()=>({dataset:{submissionConfirmationContextValue:parsedContext}})}}}
      });
      function form(){
        const c=new Legacy();let answer,posts=0,asks=0;
        Object.assign(c,{active:true,session:Symbol(),confirming:false,submitting:false,permitSubmit:false,blocked:false,submitTarget:{},statusTarget:{},fileTarget:{files:[{}]},
          stateUrlValue:'/assignments/1',contextValue:currentContext,
          confirmation:{ask:()=>{asks++;return new Promise(r=>answer=r)},cancel(){answer?.(false)},destroy(){}},
          hasSubmitTarget:true,element:{isConnected:true,requestSubmit:()=>{const e={preventDefault(){throw Error('approved submit prevented')}};c.request(e);posts++}}});
        return{c,answer:v=>answer(v),posts:()=>posts,asks:()=>asks};
      }
      const event=()=>({preventDefault(){}}),tick=()=>new Promise(r=>setImmediate(r));
      (async()=>{
        const no=form(),p=no.c.request(event());await no.c.request(event());assert.equal(no.asks(),1);no.answer(false);await p;
        assert.equal(requests,0);assert.equal(no.posts(),0);assert.equal(no.c.submitTarget.disabled,false);
        for(const action of ['cancel','disconnect']){
          const f=form(),pending=f.c.request(event());f.answer(true);await tick();
          const count=requests;f.c[action]();release();await pending;
          assert.equal(requests,count);assert.equal(f.posts(),0,'old yes cannot submit after '+action);
        }
        const changed=form(),pending=changed.c.request(event());changed.answer(true);await tick();
        changed.c.fileTarget.files=[{}];release();await pending;assert.equal(changed.posts(),0);
        const mismatch=form(),m=mismatch.c.request(event());mismatch.answer(true);await tick();parsedContext='different';release();await m;
        assert.equal(mismatch.posts(),0);assert(mismatch.c.blocked);parsedContext=currentContext;
        const yes=form(),y=yes.c.request(event());yes.answer(true);await tick();release();await y;
        assert.equal(yes.posts(),1);await yes.c.request(event());assert.equal(yes.posts(),1);assert.equal(yes.asks(),1);
      })().catch(e=>{console.error(e);process.exitCode=1});
    JS
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/controllers/submission_confirmation_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
