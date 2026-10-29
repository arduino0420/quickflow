require "spec_helper"
require "open3"

RSpec.describe "PDF touch handwriting and navigation" do
  it "starts unselected, restores reading gestures and safely toggles the existing tools" do
    script = <<~JAVASCRIPT
      const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
      const PdfInk=vm.runInNewContext(fs.readFileSync(process.argv[1],'utf8')
        .replace('export const','const').replace('export default class','class')+';PdfInk');
      const source=fs.readFileSync(process.argv[2],'utf8').replace(/^import .*$/gm,'').replace('export default class','class Preview');
      const scrolls=[],classes=new Set(),captures=new Set();
      const document={documentElement:{getAttribute:()=>null,setAttribute(){}}};
      const window={location:{hash:''},devicePixelRatio:1,cancelAnimationFrame(){},requestAnimationFrame:()=>1,
        clearTimeout(){},setTimeout:()=>1,scrollBy:(...args)=>scrolls.push(args)};
      const c=vm.runInNewContext(source+';new Preview()',{Controller:class{},window,document});
      const buttons=['pen','eraser'].map(tool=>({dataset:{pdfPreviewToolParam:tool},attrs:{},setAttribute(k,v){this.attrs[k]=v}}));
      c.element={classList:{toggle(name,on){on?classes.add(name):classes.delete(name)}}};
      c.sizesTarget={};c.sizeTargets=[];c.toolTargets=buttons;c.hasInputHelpTarget=true;c.inputHelpTarget={};
      c.load=c.watchPixelRatio=()=>{};c.connect();
      assert.equal(c.tool,null);assert(buttons.every(b=>b.attrs['aria-pressed']==='false'));
      assert(!classes.has('pdf-preview-inking'));assert(c.sizesTarget.hidden);
      const canvas={hidden:false,style:{},getBoundingClientRect:()=>({left:0,top:0,width:200,height:300}),
        getContext:()=>new Proxy({},{get:()=>()=>{}}),setPointerCapture:id=>captures.add(id),
        hasPointerCapture:id=>captures.has(id),releasePointerCapture:id=>captures.delete(id)};
      const ink=new PdfInk(canvas);ink.setViewport({width:200,height:300,transform:[1,0,0,1,0,0],
        convertToPdfPoint:(x,y)=>[x,y],convertToViewportPoint:(x,y)=>[x,y]},1);
      const state={inkCanvas:canvas,ink,cursor:{style:{}},renderedWidth:200,renderedDpr:1};
      c.pageStates=[state];c.statesByCanvas=new WeakMap([[canvas,state]]);c.containerTarget={clientWidth:200};c.draftEditable=true;
      c.showDraftStatus=()=>{};let changes=0;ink.onChange=()=>changes++;
      const event=(id,type='pointerdown',pointerType='touch')=>({type,pointerId:id,pointerType,currentTarget:canvas,
        clientX:30,clientY:40,button:0,buttons:type==='pointerup'?0:1,cancelable:true,preventDefault(){this.defaultPrevented=true}});
      for(const type of ['mouse','pen']){c.pointerDown(event(1,'pointerdown',type));c.pointerEnd(event(1,'pointerup',type))}
      assert.equal(ink.pages.get(1).length,0,'unselected mouse and pen cannot draw');
      const finger=event(2);c.pointerDown(finger);c.pointerMove({...event(2,'pointermove'),clientY:20});
      assert(!finger.defaultPrevented);assert.deepEqual(scrolls,[[0,20]]);c.pointerEnd(event(2,'pointerup'));
      assert.equal(c.touch,null);assert.equal(captures.size,0);
      const select=tool=>c.selectTool({params:{tool}});
      c.pointerDown(event(7));select('pen');
      assert.equal(c.touchMode,'blocked','switching from finger scrolling waits for that contact to lift');
      c.pointerEnd(event(7,'pointerup'));
      assert.equal(c.tool,'pen');assert(classes.has('pdf-preview-inking'));
      assert.equal(buttons[0].attrs['aria-pressed'],'true');
      c.pointerDown(event(3));assert(ink.provisional);select('pen');
      assert.equal(c.tool,null);assert.equal(ink.stroke,null);assert.equal(changes,0);
      assert(!classes.has('pdf-preview-inking'));assert.equal(c.touchMode,'blocked');
      select('eraser');c.pointerDown(event(4));assert.equal(ink.stroke,null,'held contacts cannot become eraser ink after a toggle');
      c.pointerEnd(event(3,'pointerup'));c.pointerEnd(event(4,'pointerup'));
      c.pointerDown(event(5));c.pointerEnd(event(5,'pointerup'));
      assert.equal(ink.pages.get(1)[0].tool,'eraser');assert.equal(changes,1);
      select('eraser');assert.equal(c.tool,null);assert(c.sizesTarget.hidden);
      const saved=JSON.stringify(ink.pages.get(1));
      select('pen');c.pointerDown(event(6,'pointerdown','pen'));select('pen');
      assert.equal(ink.pages.get(1).length,2,'recognized pen keeps its recorded partial stroke at deselection');
      assert.equal(c.tool,null);assert.equal(captures.size,0);
      c.trackTouches({touches:{length:2}});select('pen');
      c.pointerDown(event(8));assert.equal(ink.stroke,null,'a native pinch with cancelled pointers cannot turn into ink at selection');
      c.trackTouches({touches:{length:1}});c.pointerEnd(event(8,'pointercancel'));
      assert(c.awaitTouchRelease);c.trackTouches({touches:{length:0}});
      c.pointerDown(event(9));assert(ink.provisional);c.pointerEnd(event(9,'pointerup'));
      c.connect();assert.equal(c.tool,null,'reconnect never reselects a tool');
      assert(buttons.every(b=>b.attrs['aria-pressed']==='false'));
      assert.equal(JSON.stringify(ink.pages.get(1)[0]),JSON.stringify(JSON.parse(saved)[0]));
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/pdf_ink.js", __dir__),
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it "keeps previews out of in-flight saves and PDF snapshots, and waits for every contact to lift" do
    script = <<~JAVASCRIPT
      const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
      const load=(path,name,globals={})=>vm.runInNewContext(fs.readFileSync(path,'utf8')
        .replace(/^import .*$/gm,'').replace(/export const/g,'const')
        .replace('export default class extends','class '+name+' extends').replace('export default class','class')
        .replace(/export (async )?function/g,'$1function')+';'+name,globals);
      const PdfInk=load(process.argv[1],'PdfInk');
      const window={devicePixelRatio:1,requestAnimationFrame:()=>1,cancelAnimationFrame(){},scrollBy(){},fetch(){}};
      const document={visibilityState:'visible'};
      const Preview=load(process.argv[2],'Preview',{Controller:class{},window,document});
      const PdfDraft=load(process.argv[3],'PdfDraft',{window,document,AbortController,AbortSignal,structuredClone,setTimeout,clearTimeout});
      const snapshotPages=load(process.argv[4],'snapshotPages',{structuredClone});
      const canvas={hidden:false,getBoundingClientRect:()=>({left:0,top:0,width:200,height:300}),
        getContext:()=>new Proxy({},{get:()=>()=>{}}),setPointerCapture:id=>captured.add(id),
        hasPointerCapture:id=>captured.has(id),releasePointerCapture:id=>captured.delete(id)};
      const captured=new Set(),ink=new PdfInk(canvas);
      const viewport={width:200,height:300,transform:[1,0,0,1,0,0],
        convertToPdfPoint:(x,y)=>[x,y],convertToViewportPoint:(x,y)=>[x,y]};
      ink.setViewport(viewport,1);
      const state={inkCanvas:canvas,ink,page:{},renderedWidth:200,renderedDpr:1};
      const c=new Preview();c.statesByCanvas=new WeakMap([[canvas,state]]);c.containerTarget={clientWidth:200};
      c.showCursor=c.showDraftStatus=c.navigateTouch=()=>{};c.draftEditable=true;c.tool='pen';
      c.touchIds=new Set();c.touchPoints=new Map();c.touchMode='idle';
      const data=()=>({format_version:1,pages:[{page_number:1,operations:structuredClone(ink.pages.get(1))}]});
      const draft=new PdfDraft({url:'/fixture',context:'fixture',read:data,restore(){},status(){},editable(){},delay:60000});
      c.draft=draft;draft.ready=draft.allowed=true;draft.version=0;ink.onChange=()=>draft.changed();
      const event=(id,type='pointerdown',extra={})=>({type,currentTarget:canvas,pointerId:id,pointerType:'touch',
        button:0,buttons:type==='pointerup'?0:1,clientX:20,clientY:20,cancelable:true,preventDefault(){},...extra});
      const down=(id,extra)=>c.pointerDown(event(id,'pointerdown',extra));
      const move=(id,extra)=>c.pointerMove(event(id,'pointermove',extra));
      const up=(id,type='pointerup',extra)=>c.pointerEnd(event(id,type,extra));
      const idle=()=>{assert.equal(c.inputState,null);assert.equal(ink.stroke,null);
        assert.equal(c.touchIds.size,0);assert.equal(captured.size,0);assert.equal(c.touchMode,'idle')};
      (async()=>{
        try {
          down(1,{pointerType:'mouse'});up(1,'pointerup',{pointerType:'mouse'});
          assert.equal(draft.revision,1);
          down(10);move(10,{clientX:40});
          assert(ink.provisional);assert.equal(ink.pages.get(1).length,1);
          assert.equal(snapshotPages([state])[0].operations.length,1);
          let acknowledge;const requests=[];
          draft.call=async(method,body)=>{requests.push(structuredClone(body));return new Promise(r=>acknowledge=r)};
          const saving=draft.save();assert.equal(requests[0].draft_data.pages[0].operations.length,1);
          down(11,{clientX:80});assert.equal(ink.stroke,null);assert.equal(c.touchMode,'navigate');
          assert.equal(draft.revision,1,'discarded preview must never create a save revision');
          acknowledge({draft:{version:1}});await saving;
          assert.equal(draft.dirty,false);assert.equal(draft.confirmedSnapshot.pages[0].operations.length,1);
          up(10);assert.equal(c.touchMode,'blocked');
          move(11,{clientX:90});down(12);up(11);move(12,{clientX:100});
          assert.equal(ink.pages.get(1).length,1,'two-to-one and an added third contact cannot start ink');
          up(12);idle();
          down(13);move(13,{clientX:50});up(13);idle();
          assert.equal(ink.pages.get(1).length,2);assert.equal(draft.revision,2);
          const committed=JSON.stringify(ink.pages.get(1));
          ink.setTool('eraser');down(20);move(20,{clientX:50});
          assert.equal(ink.stroke.tool,'eraser');assert.equal(JSON.stringify(ink.pages.get(1)),committed);
          down(21);down(22);assert.equal(c.touchMode,'blocked');
          assert.equal(JSON.stringify(ink.pages.get(1)),committed,'gesture cancels only the temporary eraser');
          up(20);up(21);up(22);idle();
          down(23);up(23);assert.equal(ink.pages.get(1).at(-1).tool,'eraser');
          ink.setTool('pen');
          for(const reason of ['pointercancel','lostpointercapture','hidden','resize','tool']) {
            const before=JSON.stringify(ink.pages.get(1)),revision=draft.revision;
            down(30);move(30,{clientX:60});
            if(reason==='hidden'){document.visibilityState='hidden';c.visibilityChanged();document.visibilityState='visible'}
            else if(reason==='resize'){c.finishInput();ink.setViewport(viewport,1.5)}
            else if(reason==='tool'){c.finishInput();ink.setTool('eraser');ink.setTool('pen')}
            else up(30,reason);
            assert.equal(JSON.stringify(ink.pages.get(1)),before,reason+' cannot persist temporary ink');
            assert.equal(draft.revision,revision);up(30,'pointercancel');idle();
          }
          down(40);move(40,{clientX:80});
          down(41,{pointerType:'pen'});assert.equal(ink.provisional,false);
          const before=JSON.stringify(ink.stroke.points);
          down(42);move(42,{clientX:90});assert.equal(JSON.stringify(ink.stroke.points),before);
          up(41,'pointerup',{pointerType:'pen'});
          assert.equal(c.touchMode,'blocked','held palm cannot become ink when pen lifts');
          up(40);up(42);idle();
          assert.equal(snapshotPages([state])[0].operations.length,ink.pages.get(1).length);
          // Touch end at window level still commits/cleans up if capture was unavailable.
          down(50);c.releaseTouch(event(50,'pointerup'));idle();
          down(51);up(51,'lostpointercapture');down(52);
          assert.equal(ink.stroke,null,'lost capture waits until remaining contacts are lifted');
          c.releaseTouch(event(51,'pointercancel'));c.releaseTouch(event(52,'pointercancel'));idle();
          c.active=true;c.pagesReady=true;c.pdf={};c.submitStatusTarget={};
          const beforeSubmit=JSON.stringify(ink.pages.get(1));
          down(60);await c.submitAnswer();
          assert(c.submitStatusTarget.textContent.includes('離して'));
          assert.equal(JSON.stringify(ink.pages.get(1)),beforeSubmit,'submission cannot finalize a held touch');
          assert(ink.provisional);up(60);idle();
        } finally {draft.stop()}
      })().catch(error=>{console.error(error);process.exitCode=1});
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/pdf_ink.js", __dir__),
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__),
      File.expand_path("../../app/javascript/pdf_draft.js", __dir__),
      File.expand_path("../../app/javascript/pdf_export.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end

  it "anchors bounded PDF zoom at the two-contact midpoint and pans without changing PDF coordinates" do
    script = <<~JAVASCRIPT
      const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
      const source=fs.readFileSync(process.argv[1],'utf8').replace(/^import .*$/gm,'')
        .replace('export default class','class Preview');
      let scrollY=0,scale=1;const workspace={scrollLeft:0};
      const window={scrollBy:(x,y)=>scrollY+=y};
      const c=vm.runInNewContext(source+';new Preview()',{Controller:class{},window});
      const rect=()=>({left:-workspace.scrollLeft,top:100-scrollY,width:200*scale,height:300*scale,
        bottom:100-scrollY+300*scale});
      const sheet={getBoundingClientRect:rect};c.pageStates=[{sheet}];c.workspaceTarget=workspace;
      c.containerTarget={getBoundingClientRect:rect,style:{set width(value){scale=parseFloat(value)/100}}};
      c.layoutPages=()=>{};c.pdfScale=1;c.touchPoints=new Map([[1,{x:50,y:150}],[2,{x:150,y:150}]]);
      c.touchGesture=c.touchGeometry();
      c.touchPoints.set(1,{x:0,y:150});c.touchPoints.set(2,{x:200,y:150});c.navigateTouch();
      assert.equal(c.pdfScale,2);assert.equal(workspace.scrollLeft,100);assert.equal(scrollY,50);
      let r=rect();assert.equal((100-r.left)/r.width,.5);assert.equal((150-r.top)/r.height,1/6);
      c.touchPoints.set(1,{x:0,y:120});c.touchPoints.set(2,{x:200,y:120});c.navigateTouch();
      assert.equal(c.pdfScale,2);assert.equal(scrollY,80,'two fingers translated upward scroll down');
      c.touchPoints.set(1,{x:-1000,y:120});c.touchPoints.set(2,{x:1200,y:120});c.navigateTouch();
      assert.equal(c.pdfScale,3,'zoom is capped to bound memory/scroll extent');
      c.touchPoints.set(1,{x:90,y:120});c.touchPoints.set(2,{x:110,y:120});c.navigateTouch();
      assert.equal(c.pdfScale,1,'zoom cannot shrink below fit-to-width');
      assert.equal(scale,1);
    JAVASCRIPT
    stdout, stderr, status = Open3.capture3("node", "-e", script,
      File.expand_path("../../app/javascript/controllers/pdf_preview_controller.js", __dir__))
    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
