require "spec_helper"
require "open3"

RSpec.describe "PDF preview input isolation" do
  it "records consecutive pen strokes and cancels native actions only for the ink input" do
    script = <<~JAVASCRIPT
      const fs = require('node:fs');
      const vm = require('node:vm');
      const assert = require('node:assert/strict');
      const inkSource = fs.readFileSync(process.argv[1], 'utf8')
        .replace('export const', 'const').replace('export default class', 'class');
      const PdfInk = vm.runInNewContext(inkSource + '; PdfInk');
      const source = fs.readFileSync(process.argv[2], 'utf8').replace(/^import .*$/gm, '')
        .replace('export default class', 'class Preview');
      const scrolls = []; let cancelledFrames=0;
      const document={addEventListener(){},removeEventListener(){}};
      const window={devicePixelRatio:1,scrollBy:(...args)=>scrolls.push(args),addEventListener(){},removeEventListener(){},
        requestAnimationFrame:()=>1,cancelAnimationFrame(id) {if(id) cancelledFrames++;}};
      const PdfInputDiagnostics=vm.runInNewContext(fs.readFileSync(process.argv[3],'utf8')
        .replace('export default class','class')+'; PdfInputDiagnostics',{document,window,performance});
      const c = vm.runInNewContext(source + '; new Preview()', {
        Controller: class {}, window, PdfInputDiagnostics
      });
      const captures = new Set();
      const canvas = {hidden:false, getBoundingClientRect:()=>({left:0,top:0,width:200,height:300}),
        getContext:()=>new Proxy({}, {get:()=>()=>{}}),
        setPointerCapture:id=>captures.add(id), hasPointerCapture:id=>captures.has(id),
        releasePointerCapture:id=>captures.delete(id)};
      const ink = new PdfInk(canvas);
      ink.setViewport({width:200,height:300,transform:[1,0,0,1,0,0],
        convertToPdfPoint:(x,y)=>[x,y], convertToViewportPoint:(x,y)=>[x,y]}, 1);
      let changes = 0;
      ink.onChange = () => changes++;
      const state = {inkCanvas:canvas, ink, renderedWidth:200, renderedDpr:1};
      c.statesByCanvas = new WeakMap([[canvas,state]]);
      c.element={contains:target=>target===canvas};
      c.containerTarget = {clientWidth:200}; c.draftEditable = true;
      c.showCursor = c.showDraftStatus = () => {};
      c.startInputDiagnostics();
      const event = (extra={}) => ({type:'pointerdown',target:canvas,currentTarget:canvas, pointerId:1, pointerType:'pen',
        button:0, buttons:1, clientX:20, clientY:20, cancelable:true, defaultPrevented:false,
        preventDefault() {this.defaultPrevented=true;}, ...extra});
      for (let i=0;i<10;i++) {
        const down=event({pointerId:1}); c.pointerDown(down);
        assert(down.defaultPrevented);
        const move=event({type:'pointermove',pointerId:1,clientX:40}); c.pointerMove(move);
        assert(move.defaultPrevented);
        assert.equal(c.inkFrame,1);
        c.pointerEnd(event({pointerId:1,type:'pointerup',buttons:0,clientX:50}));
        assert.equal(c.inkFrame,null);
        c.pointerEnd(event({pointerId:1,type:'lostpointercapture',buttons:0}));
        assert.equal(c.inputState,null); assert.equal(captures.size,0);
      }
      assert.equal(ink.pages.get(1).length,10);
      assert(ink.pages.get(1).every(op=>op.points.length===3));
      assert.equal(cancelledFrames,10);
      assert.equal(changes,10,'every completed stroke must notify autosave');
      assert.equal(c.inputDiagnostics.summary().accepted,10);
      assert.equal(c.inputDiagnostics.summary().ended,10);
      assert.equal(c.inputDiagnostics.summary().pen.controller.lostpointercapture,10);
      for (const type of ['pointercancel','lostpointercapture']) {
        c.pointerDown(event()); c.pointerEnd(event({type}));
        c.pointerDown(event()); assert(c.inputState);
        c.pointerEnd(event({type:'pointerup'}));
      }
      for (const unavailable of ['draft','resize']) {
        c.draftEditable = unavailable !== 'draft';
        state.renderedWidth = unavailable === 'resize' ? 100 : 200;
        const before=ink.pages.get(1).length, down=event(); c.pointerDown(down);
        assert(down.defaultPrevented); assert.equal(ink.pages.get(1).length,before);
      }
      c.draftEditable=true; state.renderedWidth=200;
      const right=event({pointerType:'mouse',button:2}); c.pointerDown(right);
      assert.equal(right.defaultPrevented,false);
      const outside=event({currentTarget:{}}); c.pointerDown(outside);
      assert.equal(outside.defaultPrevented,false);
      const finger=event({pointerType:'touch',pointerId:90});
      const count=ink.pages.get(1).length; c.pointerDown(finger);
      const drag=event({pointerType:'touch',pointerId:90,clientY:10}); c.pointerMove(drag);
      assert.equal(finger.defaultPrevented,false); assert.equal(drag.defaultPrevented,false);
      assert.equal(JSON.stringify(scrolls),JSON.stringify([[0,10]]));
      c.pointerEnd(event({pointerType:'touch',pointerId:90,type:'pointerup'}));
      assert.equal(ink.pages.get(1).length,count);
      c.pointerDown(event());
      const unrelated=event({pointerId:99}); c.pointerMove(unrelated);
      assert.equal(unrelated.defaultPrevented,false);
      c.pointerEnd(event({type:'pointerup'}));
      const strokes=ink.pages.get(1).length, scrollCount=scrolls.length;
      c.pointerDown(event({pointerType:'touch',pointerId:91}));
      c.pointerDown(event({pointerType:'touch',pointerId:92}));
      assert.equal(c.multiTouch,true); assert.equal(c.touch,null);
      c.pointerMove(event({pointerType:'touch',pointerId:91,clientY:1}));
      const duringPinch=event({pointerType:'mouse'}); c.pointerDown(duringPinch);
      assert.equal(c.inputState,null); assert.equal(ink.pages.get(1).length,strokes);
      assert.equal(scrolls.length,scrollCount,'two fingers must not trigger manual scrolling');
      c.pointerEnd(event({pointerType:'touch',pointerId:91,type:'pointercancel'}));
      assert.equal(c.multiTouch,true);
      c.pointerEnd(event({pointerType:'touch',pointerId:92,type:'pointercancel'}));
      assert.equal(c.multiTouch,false);
      c.pointerDown(event()); assert(c.inputState);
      // A palm contact must neither scroll nor end a held pen stroke.
      c.pointerDown(event({pointerType:'touch',pointerId:93}));
      c.pointerMove(event({pointerType:'touch',pointerId:93,clientY:1}));
      assert(c.inputState); assert.equal(scrolls.length,scrollCount);
      c.pointerEnd(event({pointerType:'touch',pointerId:93,type:'pointerup'}));
      c.pointerEnd(event({type:'pointerup'}));
      const previousCount=ink.pages.get(1).length;
      for (let i=0;i<10;i++) {
        c.pointerDown(event({timeStamp:i*2,clientX:20,clientY:20}));
        c.pointerEnd(event({type:'pointerup',buttons:0,timeStamp:i*2+1,clientX:20+(i%2)*0.1}));
        c.pointerEnd(event({type:'lostpointercapture',buttons:0,timeStamp:i*2+1}));
        assert.equal(c.inputState,null);
      }
      const shortStrokes=ink.pages.get(1).slice(previousCount);
      assert.equal(shortStrokes.length,10);
      assert(shortStrokes.every((op,i)=>op.points.length===1+i%2));
      const summary=c.inputDiagnostics.summary();
      assert.equal(summary.reasons['pinch-active'] || 0,0,'genuine pen is no longer rejected by palm contacts');
      assert(c.inputDiagnostics.snapshot().rows.some(row=>row.reason==='pinch-active' && row.pointerType==='mouse'));
      assert.equal(summary.reasons['draft-not-editable'],1);
      assert.equal(summary.reasons['viewport-mismatch'],1);
      assert.equal(summary.accepted,ink.pages.get(1).length,'diagnostics must not change stroke creation');
      c.stopInputDiagnostics();
      for (const type of ['selectstart','contextmenu']) {
        const selection=event({type}); c.preventPageSelection(selection);
        assert(selection.defaultPrevented);
      }
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/pdf_ink.js", __dir__),
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__),
      File.expand_path("../../app/javascript/controllers/pdf_input_diagnostics.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it "cancels only explicit single-stylus touches and releases canvas listeners" do
    script = <<~JAVASCRIPT
      const fs = require('node:fs');
      const vm = require('node:vm');
      const assert = require('node:assert/strict');
      const source = fs.readFileSync(process.argv[1], 'utf8').replace(/^import .*$/gm, '')
        .replace('export default class', 'class Preview');
      const c = vm.runInNewContext(source + '; new Preview()', {Controller: class {}});
      const stylus={touchType:'stylus'}, finger={touchType:'direct'}, unknown={};
      const listeners=new Map(); let added=0, removed=0;
      const canvas={
        addEventListener(type, listener, options) {
          assert.equal(options.passive,false);
          assert(!listeners.has(type),'duplicate listener');
          listeners.set(type,listener); added++;
        },
        removeEventListener(type, listener) {
          assert.equal(listeners.get(type),listener);
          listeners.delete(type); removed++;
        }
      };
      const send=(type,changedTouches,touches,cancelable=true)=>{
        let calls=0;
        const event={type,changedTouches,touches,cancelable,preventDefault(){calls++}};
        listeners.get(type)?.(event);
        return calls;
      };
      c.inkTargetConnected(canvas); c.inkTargetConnected(canvas);
      assert.equal(added,3);
      // touchend has no active touches; changedTouches still identifies the pen.
      assert.equal(send('touchstart',[stylus],[stylus]),1);
      assert.equal(send('touchend',[stylus],[]),1);
      for(const type of ['touchstart','touchend']) {
        for(const [changed,active,cancelable] of [
          [[finger],[finger],true], [[finger],[],true], [[unknown],[unknown],true],
          [[unknown],[],true], [[],[],true], [[stylus,finger],[],true],
          [[stylus,stylus],[],true], [[stylus],[stylus,finger],true],
          [[stylus],[finger],true], [[stylus],[unknown],true],
          [[stylus],[{touchType:"stylus",identifier:99}],true],
          [[finger],[stylus],true], [[finger,finger],[finger,finger],true],
          [[stylus],[stylus,stylus],true], [[stylus],[],false]
        ]) assert.equal(send(type,changed,active,cancelable),0);
      }
      assert.equal(send('touchstart',[stylus],[]),0);
      assert.equal(send('touchend',[stylus],[stylus]),0);
      // A finger immediately after the pen, and both stages of a pinch, stay native.
      assert.equal(send('touchend',[stylus],[]),1);
      assert.equal(send('touchstart',[finger],[finger]),0);
      assert.equal(send('touchstart',[finger],[finger,finger]),0);
      assert.equal(send('touchend',[finger],[finger]),0);
      c.inkTargetDisconnected(canvas); c.inkTargetDisconnected(canvas);
      assert.equal(removed,3); assert.equal(listeners.size,0);
      assert.equal(send('touchstart',[stylus],[stylus]),0);
      c.inkTargetConnected(canvas);
      assert.equal(added,6);
      assert.equal(send('touchstart',[stylus],[stylus]),1);
      c.inkTargetDisconnected(canvas);
      assert.equal(c.inkTouchListeners.size,0);
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
  it "prioritizes genuine pen input over palm contacts without turning fingers into ink" do
    script = <<~JAVASCRIPT
      const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
      const PdfInk = vm.runInNewContext(fs.readFileSync(process.argv[1],'utf8')
        .replace('export const','const').replace('export default class','class')+';PdfInk');
      const source=fs.readFileSync(process.argv[2],'utf8').replace(/^import .*$/gm,'')
        .replace('export default class','class Preview');
      const scrolls=[];
      const window={devicePixelRatio:1,scrollBy:(...v)=>scrolls.push(v),requestAnimationFrame:()=>1,cancelAnimationFrame(){}};
      const c=vm.runInNewContext(source+';new Preview()',{Controller:class{},window});
      const captured=new Set();
      const canvas={hidden:false,getBoundingClientRect:()=>({left:0,top:0,width:200,height:300}),
        getContext:()=>new Proxy({},{get:()=>()=>{}}),setPointerCapture:id=>captured.add(id),
        hasPointerCapture:id=>captured.has(id),releasePointerCapture:id=>captured.delete(id)};
      const ink=new PdfInk(canvas);
      ink.setViewport({width:200,height:300,transform:[1,0,0,1,0,0],
        convertToPdfPoint:(x,y)=>[x,y],convertToViewportPoint:(x,y)=>[x,y]},1);
      let saves=0;ink.onChange=()=>saves++;
      const state={inkCanvas:canvas,ink,renderedWidth:200,renderedDpr:1};
      c.statesByCanvas=new WeakMap([[canvas,state]]);c.containerTarget={clientWidth:200};c.draftEditable=true;
      c.showCursor=c.showDraftStatus=()=>{};
      const event=(extra={})=>({type:'pointerdown',currentTarget:canvas,target:canvas,pointerId:1,pointerType:'pen',
        button:0,buttons:1,clientX:20,clientY:20,cancelable:true,preventDefault(){},...extra});
      c.pointerDown(event({pointerType:'touch',pointerId:10}));
      c.pointerDown(event({pointerType:'touch',pointerId:11}));
      assert.equal(c.multiTouch,true);assert.equal(ink.pages.get(1).length,0);
      c.pointerDown(event());
      assert.equal(c.inputState,state,'a real pen must not be rejected as a pinch while the palm rests');
      assert.equal(c.multiTouch,false);assert.equal(c.touch,null);assert.equal(c.touchIds.size,0);
      assert(captured.has(1));assert(!captured.has(10));
      for(const id of [12,13]) {
        c.pointerDown(event({pointerType:'touch',pointerId:id}));
        c.pointerMove(event({type:'pointermove',pointerType:'touch',pointerId:id,clientY:5}));
      }
      assert.equal(c.inputState,state,'two palm contacts must not end a held pen');
      assert.equal(saves,0);assert.equal(scrolls.length,0);
      let prevented=0;
      c.preventStylusGesture({type:'touchstart',currentTarget:canvas,cancelable:true,
        changedTouches:[{touchType:'direct'}],touches:[{},{}],preventDefault(){prevented++}});
      assert.equal(prevented,1,'palm touch gestures on the pen canvas must not cancel native pen input');
      c.preventStylusGesture({type:'touchstart',currentTarget:{},cancelable:true,
        changedTouches:[{touchType:'direct'}],touches:[{},{}],preventDefault(){prevented++}});
      assert.equal(prevented,1,'controls and other canvases keep their native gestures');
      c.preventStylusGesture({type:'touchmove',currentTarget:canvas,cancelable:true,
        changedTouches:[{touchType:'direct'}],touches:[{},{}],preventDefault(){prevented++}});
      assert.equal(prevented,2,'existing palm contacts must not initiate a native pinch during pen input');
      c.pointerMove(event({type:'pointermove',clientX:50}));
      c.pointerEnd(event({type:'pointerup',buttons:0,clientX:60}));
      assert.equal(saves,1);assert.equal(ink.pages.get(1).length,1);
      assert.equal(ink.pages.get(1)[0].points.length,3);assert.equal(c.inputState,null);
      for(const id of [10,11,12,13])c.pointerEnd(event({type:'pointerup',pointerType:'touch',pointerId:id}));
      c.pointerDown(event({pointerType:'touch',pointerId:20}));
      c.pointerMove(event({type:'pointermove',pointerType:'touch',pointerId:20,clientY:5}));
      assert.equal(scrolls.length,1);assert.equal(ink.pages.get(1).length,1,'finger remains scroll-only');
      c.pointerEnd(event({type:'pointerup',pointerType:'touch',pointerId:20}));
      c.pointerDown(event({pointerType:'touch',pointerId:21}));c.pointerDown(event({pointerType:'touch',pointerId:22}));
      assert.equal(c.multiTouch,true,'genuine finger pinch remains available when no pen is down');
      c.pointerEnd(event({type:'pointercancel',pointerType:'touch',pointerId:21}));
      c.pointerEnd(event({type:'pointercancel',pointerType:'touch',pointerId:22}));
      c.draftEditable=false;c.pointerDown(event());assert.equal(c.inputState,null);
      assert.equal(ink.pages.get(1).length,1,'submitted/read-only pages remain non-writing');
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/pdf_ink.js", __dir__),
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
