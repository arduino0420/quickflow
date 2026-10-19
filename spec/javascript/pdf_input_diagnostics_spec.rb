require "spec_helper"
require "open3"

RSpec.describe "Opt-in PDF input diagnostics" do
  it "correlates document and controller events without recording answers or changing input decisions" do
    script = <<~JAVASCRIPT
      const fs = require('node:fs');
      const vm = require('node:vm');
      const assert = require('node:assert/strict');
      const listeners = new Map();
      const document = {
        documentElement: {removeAttribute(){}},
        addEventListener(type, callback, options) {
          assert.equal(options.capture,true); assert.equal(options.passive,true);
          assert(!listeners.has(type)); listeners.set(type,callback);
        },
        removeEventListener(type,callback,capture) {
          assert.equal(capture,true); assert.equal(listeners.get(type),callback); listeners.delete(type);
        }
      };
      const load = (path, name, globals={}) => vm.runInNewContext(
        fs.readFileSync(path,'utf8').replace(/^import .*$/gm,'')
          .replace('export const','const').replace('export default class PdfInputDiagnostics', 'class '+name)
          .replace('export default class', 'class '+name)
          + '; '+name, globals);
      // PdfInk already has a class name; remove only its export prefix.
      const PdfInk = vm.runInNewContext(fs.readFileSync(process.argv[1],'utf8')
        .replace('export const','const').replace('export default class','class')+'; PdfInk');
      const Diagnostics = load(process.argv[2], 'Diagnostics', {document,performance});
      const Preview = load(process.argv[3], 'Preview', {Controller:class {}, PdfInputDiagnostics:Diagnostics, document,
        window:{devicePixelRatio:1,cancelAnimationFrame(){},clearTimeout(){},requestAnimationFrame:()=>1,scrollBy(){}}});
      const c = new Preview();
      const captures = new Set();
      const canvas = {hidden:false, getBoundingClientRect:()=>({left:0,top:0,width:200,height:300}),
        getContext:()=>new Proxy({}, {get:()=>()=>{}}),
        setPointerCapture:id=>captures.add(id),hasPointerCapture:id=>captures.has(id),
        releasePointerCapture:id=>captures.delete(id)};
      const ink = new PdfInk(canvas);
      ink.setViewport({width:200,height:300,transform:[1,0,0,1,0,0],
        convertToPdfPoint:(x,y)=>[x,y],convertToViewportPoint:(x,y)=>[x,y]},1);
      let changes=0; ink.onChange=()=>changes++;
      const state={ink,inkCanvas:canvas,renderedWidth:200,renderedDpr:1};
      c.statesByCanvas=new WeakMap([[canvas,state]]);
      c.element={contains:target=>target===canvas};
      c.containerTarget={clientWidth:200}; c.draftEditable=true;
      c.showCursor=c.showDraftStatus=()=>{};
      const event=(type,extra={})=>({type,target:canvas,currentTarget:canvas,pointerId:1,pointerType:'pen',
        timeStamp:100,button:0,buttons:type==='pointerup'?0:1,clientX:20,clientY:20,cancelable:true,
        preventDefault(){this.defaultPrevented=true;},
        answer:'PRIVATE_ANSWER',credential:'PRIVATE_TOKEN',...extra});
      const send=(type,extra={})=>{
        const e=event(type,extra); listeners.get(type)?.(e);
        if(type==='pointerdown') c.pointerDown(e);
        else if(type==='pointermove') c.pointerMove(e);
        else c.pointerEnd(e);
        return e;
      };
      assert.equal(listeners.size,0);
      send('pointerdown'); send('pointerup');
      assert.equal(c.inputDiagnostics,undefined); assert.equal(changes,1);
      c.startInputDiagnostics();
      assert.equal(listeners.size,5);
      const down=send('pointerdown',{timeStamp:200});
      send('pointerdown',{timeStamp:201}); // Preserve current input-busy behavior.
      assert(c.inputState); assert(ink.stroke);
      send('pointerup',{timeStamp:202});
      send('lostpointercapture',{timeStamp:203});
      send('pointerdown',{timeStamp:204});
      send('pointermove',{timeStamp:205,clientX:40});
      send('pointerup',{timeStamp:206});
      assert.equal(ink.pages.get(1).length,3); assert.equal(changes,3);
      const report=c.inputDiagnostics.snapshot();
      const docDown=report.rows.find(r=>r.source==='document' && r.eventTimeMs===200);
      const ctrlDown=report.rows.find(r=>r.reason==='down-enter' && r.eventTimeMs===200);
      assert.equal(docDown.eventId,ctrlDown.eventId);
      assert.equal(docDown.type,'pointerdown'); assert.equal(docDown.pointerType,'pen');
      assert.equal(docDown.pointerId,1); assert.equal(docDown.inputActive,false);
      assert(report.rows.some(r=>r.reason==='stroke-started' && r.inputActive && r.activeStroke && r.captured));
      assert(report.rows.some(r=>r.reason==='input-busy' && r.inputActive));
      assert(report.rows.some(r=>r.reason==='stroke-ended' && !r.inputActive && !r.activeStroke));
      assert(report.rows.some(r=>r.type==='lostpointercapture' && r.reason==='end-without-matching-stroke'));
      const documentOnly=event('pointerdown',{timeStamp:207});
      listeners.get('pointerdown')(documentOnly);
      const documentOnlyRow=c.inputDiagnostics.snapshot().rows.at(-1);
      assert.equal(documentOnlyRow.source,'document');
      assert(!c.inputDiagnostics.snapshot().rows.some(r=>r.source==='controller' && r.eventId===documentOnlyRow.eventId));
      const privateEvent=event('pointermove');
      for(const key of ['clientX','clientY','pressure','answer','credential']) {
        Object.defineProperty(privateEvent,key,{get(){throw Error('diagnostics read private input: '+key);}});
      }
      listeners.get('pointermove')(privateEvent);
      const serialized=JSON.stringify(c.inputDiagnostics.snapshot());
      for(const secret of ['PRIVATE_ANSWER','PRIVATE_TOKEN','clientX','clientY','points','target:']) assert(!serialized.includes(secret));
      assert(report.rows.every(r=>Object.values(r).every(v=>v===null || ['string','number','boolean'].includes(typeof v))));
      report.rows[0].reason='modified'; assert.notEqual(c.inputDiagnostics.snapshot().rows[0].reason,'modified');
      // A late loss with a reused ID still ends the stroke: diagnostics must not fix it.
      send('pointerdown',{timeStamp:210});
      send('lostpointercapture',{timeStamp:211});
      assert.equal(c.inputState,null); assert.equal(ink.stroke,null);
      assert(c.inputDiagnostics.snapshot().rows.some(r=>r.type==='lostpointercapture' && r.reason==='stroke-ended'));
      for (const gap of [1,500]) {
        send('pointerdown',{timeStamp:1000}); send('pointerup',{timeStamp:1001});
        send('pointerdown',{timeStamp:1001+gap}); send('pointerup',{timeStamp:1002+gap});
        const starts=c.inputDiagnostics.snapshot().rows.filter(r=>r.reason==='stroke-started').slice(-2);
        assert.equal(starts[1].eventTimeMs-starts[0].eventTimeMs,1+gap);
        assert.equal(c.inputState,null);
      }
      c.draftEditable=false; send('pointerdown',{timeStamp:220});
      assert(c.inputDiagnostics.snapshot().rows.some(r=>r.reason==='draft-not-editable'));
      c.draftEditable=true; state.renderedWidth=100; send('pointerdown',{timeStamp:230});
      assert(c.inputDiagnostics.snapshot().rows.some(r=>r.reason==='viewport-mismatch'));
      const outside=event('pointerdown',{target:{},currentTarget:document,pointerType:'touch'});
      const before=c.inputDiagnostics.snapshot().total;
      listeners.get('pointerdown')(outside); assert.equal(c.inputDiagnostics.snapshot().total,before);
      listeners.get('pointerdown')(event('pointerdown',{target:{},currentTarget:document}));
      assert.equal(c.inputDiagnostics.snapshot().rows.at(-1).target,'outside-preview');
      for(let i=0;i<2200;i++) listeners.get('pointermove')(event('pointermove',{timeStamp:300+i}));
      const bounded=c.inputDiagnostics.snapshot();
      assert.equal(bounded.rows.length,2048); assert.equal(bounded.dropped,bounded.total-2048);
      assert.equal(bounded.rows[0].sequence,bounded.dropped+1);
      assert.equal(bounded.rows.at(-1).sequence,bounded.total);
      c.finishInput({type:'blur',target:{}});
      assert(c.inputDiagnostics.snapshot().rows.some(r=>r.reason==='window-blurred'));
      const old=c.inputDiagnostics; c.startInputDiagnostics();
      assert.equal(old.snapshot().total,0); assert.equal(listeners.size,5);
      assert.equal(c.inputDiagnostics.snapshot().total,0);
      c.stopInputDiagnostics(); assert.equal(listeners.size,0); assert.equal(c.inputDiagnostics,null);
      state.renderedWidth=200; send('pointerdown'); send('pointercancel');
      assert.equal(c.inputState,null);
      c.startInputDiagnostics(); c.pageStates=[]; c.previousTurboSetting=null;
      c.disconnect(); assert.equal(listeners.size,0); assert.equal(c.inputDiagnostics,null);
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/pdf_ink.js", __dir__),
      File.expand_path("../../app/javascript/controllers/pdf_input_diagnostics.js", __dir__),
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
