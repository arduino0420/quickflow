require "spec_helper"
require "open3"

RSpec.describe "Read-only answer PDF lifecycle" do
  it "discards pending render results and releases resources when navigation disconnects the viewer" do
    script = <<~JAVASCRIPT
      const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
      const source = fs.readFileSync(process.argv[1], 'utf8').replace(/^import .*$/gm, '')
        .replace('export default class', 'class Viewer');
      const canvases = [];
      const c = vm.runInNewContext(source + '; new Viewer()', {
        Controller: class {}, window: {devicePixelRatio: 3},
        document: {createElement() {return {dataset:{}, setAttribute(){}, getContext(){return {};}};}}
      });
      c.active = true; c.session = Symbol(); c.revision = 0; c.pageNumber=1; c.queue = Promise.resolve();
      c.statusTarget = {textContent:'loading'};
      c.pagesTarget = {clientWidth:320, replaceChildren(){canvases.length=0;},
        append(canvas){canvases.push(canvas);}, querySelectorAll(){return canvases;}};
      let resolve, cancelled=0, destroyed=0, disconnected=0, cleaned=0, pages=0;
      c.pdf = {numPages:2, async getPage() {
        pages++;
        return {getViewport({scale}) {return {width:100*scale,height:200*scale};},
          render() {return {promise:new Promise(r=>resolve=r),cancel(){cancelled++;}};},
          cleanup(){cleaned++;}};
      }};
      c.observer={disconnect(){disconnected++;}};
      c.loadingTask={destroy(){destroyed++;return Promise.resolve();}};
      c.pdfWorker={destroy(){destroyed++;}}; c.worker={terminate(){destroyed++;}};
      (async()=>{
        c.scheduleRender(); await new Promise(r=>setImmediate(r));
        assert.equal(pages,1,'only one page renders at a time');
        assert.equal(canvases[0].width,640,'pixel ratio is bounded at two');
        const oldSession=c.session;
        c.disconnect(); resolve(); await c.queue;
        assert.equal(pages,1,'no later page renders after navigation');
        assert.equal(canvases[0].width,0); assert.equal(canvases[0].height,0);
        assert.equal(canvases[0].dataset.rendered,undefined);
        assert.equal(c.statusTarget.textContent,'答案PDFを読み込んでいます。');
        assert.equal(cancelled,1); assert.equal(cleaned,1);
        assert.equal(destroyed,3); assert.equal(disconnected,1);
        c.active=true; c.session=Symbol();
        assert.equal(c.current(oldSession),false,'reconnect does not revive stale work');
        c.fail(); assert.equal(c.statusTarget.textContent,'答案PDFを表示できませんでした。時間をおいて画面を再読み込みしてください。');
      })().catch(error=>{console.error(error);process.exitCode=1;});
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/controllers/answer_pdf_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
  it "gives reload guidance without retries for HTTP, worker and render failures" do
    script = <<~JAVASCRIPT
      const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
      const source=fs.readFileSync(process.argv[1],'utf8').replace(/^import .*$/gm,'')
        .replace('await import("pdfjs")','mockPdfjs').replace('export default class','class Viewer');
      const guidance='答案PDFを表示できませんでした。時間をおいて画面を再読み込みしてください。';
      (async()=>{
        for(const status of [401,404,500]){
          let loads=0;
          const c=vm.runInNewContext(source+';new Viewer()',{
            Controller:class{},Worker:class{addEventListener(){}},
            mockPdfjs:{PDFWorker:class{},getDocument(){loads++;return{promise:Promise.reject(Object.assign(Error('private response'),{status}))}}}
          });
          Object.assign(c,{active:true,session:Symbol(),statusTarget:{},assetsUrlValue:'/local/',urlValue:'/authorized-answer'});
          await c.load(c.session);assert.equal(loads,1);assert.equal(c.statusTarget.textContent,guidance);
        }
        let errorEvent,rejectLoad,loads=0;
        const c=vm.runInNewContext(source+';new Viewer()',{
          Controller:class{},Worker:class{addEventListener(name,callback){errorEvent=callback}},
          mockPdfjs:{PDFWorker:class{},getDocument(){loads++;return{promise:new Promise((_,reject)=>rejectLoad=reject)}}}
        });
        Object.assign(c,{active:true,session:Symbol(),statusTarget:{},assetsUrlValue:'/local/',urlValue:'/authorized-answer'});
        const pending=c.load(c.session);errorEvent();assert.equal(c.statusTarget.textContent,guidance);
        c.active=false;rejectLoad(Error('worker stopped'));await pending;assert.equal(loads,1);
        c.active=true;c.session=Symbol();c.revision=0;c.queue=Promise.resolve();c.render=async()=>{throw Error('private render')};
        c.scheduleRender();await c.queue;assert.equal(c.statusTarget.textContent,guidance);assert.equal(c.revision,1);
      })().catch(error=>{console.error(error);process.exitCode=1});
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/controllers/answer_pdf_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
