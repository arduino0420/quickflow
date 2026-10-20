require "rails_helper"
require "capybara/rspec"
require "selenium-webdriver"
require "fileutils"

RSpec.describe "Draft sampling candidates (not connected to saving)", type: :system do
  it "measures actual quadratic rendering and generated PDFs without modifying original operations" do
    Selenium::WebDriver.logger.level = :warn
    driven_by :selenium, using: :headless_chrome, screen_size: [ 1280, 900 ]
    visit student_login_path
    result = Capybara.using_wait_time(90) do
      page.evaluate_async_script(<<~JS)
        const done=arguments[arguments.length-1];
        (async()=>{
          const experiment=(()=>{#{File.read(Rails.root.join("spec/support/draft_sampling_experiment.js"))}})();
          const {default:PdfInk}=await import('pdf_ink');
          const {generateAnswerPdf}=await import('pdf_export');
          const {PDFDocument}=await import('pdf-lib');
          const pdfjs=await import('pdfjs');
          const worker=new Worker('/vendor/pdfjs/6.4.299/pdf.worker.min.mjs',{type:'module'});
          const pdfWorker=new pdfjs.PDFWorker({port:worker});
          const blank=await PDFDocument.create();blank.addPage([200,300]);const source=await blank.save();
          const sourceTask=pdfjs.getDocument({data:source.slice(),worker:pdfWorker});
          const document=await sourceTask.promise;
          const sourcePage=await document.getPage(1), original=JSON.stringify(experiment.operations);
          const draw=(operations,scale)=>{
            const canvas=window.document.createElement('canvas'),ink=new PdfInk(canvas);
            ink.pages.set(1,operations);ink.setViewport(sourcePage.getViewport({scale}),1);return canvas;
          };
          const pixels=canvas=>canvas.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data;
          const difference=(a,b,width,height,bounds=null,scale=1,white=false)=>{
            const region=bounds?[Math.max(0,Math.floor(bounds[0]*scale)),Math.max(0,Math.floor((300-bounds[3])*scale)),
              Math.min(width,Math.ceil(bounds[2]*scale)),Math.min(height,Math.ceil((300-bounds[1])*scale))]:[0,0,width,height];
            let changedPixels=0,maxChannelDelta=0,totalDelta=0,originalInkPixels=0,candidateInkPixels=0;
            for(let y=region[1];y<region[3];y++)for(let x=region[0];x<region[2];x++){
              const at=(y*width+x)*4;let changed=false;
              for(let c=0;c<4;c++){const delta=Math.abs(a[at+c]-b[at+c]);changed ||= delta>0;maxChannelDelta=Math.max(maxChannelDelta,delta);totalDelta+=delta;}
              if(changed)changedPixels++;
              if(white?a[at]<250:a[at+3]>0)originalInkPixels++;
              if(white?b[at]<250:b[at+3]>0)candidateInkPixels++;
            }
            return {changedPixels,maxChannelDelta,totalDelta,originalInkPixels,candidateInkPixels};
          };
          const picture=operations=>{
            const canvas=draw(operations,2),context=canvas.getContext('2d');
            context.resetTransform();context.globalCompositeOperation='destination-over';context.fillStyle='white';
            context.fillRect(0,0,canvas.width,canvas.height);const png=canvas.toDataURL();canvas.width=canvas.height=0;return png;
          };
          const results=[];let originalPdfPng;
          for(const candidate of experiment.candidates){
            const metadataPreserved=candidate.operations.every((op,index)=>{
              const before=experiment.operations[index];
              return op.id===before.id&&op.tool===before.tool&&op.width===before.width&&op.color===before.color&&
                JSON.stringify(op.points[0])===JSON.stringify(before.points[0])&&JSON.stringify(op.points.at(-1))===JSON.stringify(before.points.at(-1))&&
                (op.tool!=='eraser'||JSON.stringify(op)===JSON.stringify(before));
            });
            const preview=[];
            for(const scale of [1,2,8]){
              const a=draw(experiment.operations,scale),b=draw(candidate.operations,scale),ap=pixels(a),bp=pixels(b);
              preview.push({scale,...difference(ap,bp,a.width,a.height),glyphs:experiment.groups.map(group=>
                ({name:group.name,...difference(ap,bp,a.width,a.height,group.bounds,scale)}))});
              a.width=a.height=b.width=b.height=0;
            }
            const exports=[];
            for(const operations of [experiment.operations,candidate.operations]){
              const bytes=await generateAnswerPdf({source:source.slice(),pages:[{page:sourcePage,operations}]});
              const exportWorker=new Worker('/vendor/pdfjs/6.4.299/pdf.worker.min.mjs',{type:'module'});
              const exportPdfWorker=new pdfjs.PDFWorker({port:exportWorker});
              const exportTask=pdfjs.getDocument({data:bytes.slice(),worker:exportPdfWorker});
              const reopened=await exportTask.promise;
              const page=await reopened.getPage(1),viewport=page.getViewport({scale:240/72});
              const canvas=window.document.createElement('canvas');canvas.width=Math.ceil(viewport.width);canvas.height=Math.ceil(viewport.height);
              await page.render({canvasContext:canvas.getContext('2d'),viewport}).promise;
              exports.push({canvas,bytes:bytes.length,pageCount:reopened.numPages});await exportTask.destroy();exportPdfWorker.destroy();exportWorker.terminate();
            }
            const [a,b]=exports,ap=pixels(a.canvas),bp=pixels(b.canvas);
            const pdf={dpi:240,originalBytes:a.bytes,candidateBytes:b.bytes,pageCount:b.pageCount,
              ...difference(ap,bp,a.canvas.width,a.canvas.height,null,240/72,true),glyphs:experiment.groups.map(group=>
                ({name:group.name,...difference(ap,bp,a.canvas.width,a.canvas.height,group.bounds,240/72,true)}))};
            results.push({name:candidate.name,metadataPreserved,...experiment.measure(candidate.operations),preview,pdf,
              previewPng:picture(candidate.operations),pdfPng:b.canvas.toDataURL()});
            originalPdfPng ||= a.canvas.toDataURL();
            for(const {canvas} of exports)canvas.width=canvas.height=0;
          }
          const report={synthetic:true,productionSavingConnected:false,originalUnchanged:original===JSON.stringify(experiment.operations),
            original:experiment.measure(experiment.operations),longWriting:experiment.longWriting,results,
            originalPreviewPng:picture(experiment.operations),originalPdfPng};
          await sourceTask.destroy();pdfWorker.destroy();worker.terminate();done(report);
        })().catch(error=>done({experimentError:String(error)}));
      JS
    end
    expect(result).not_to have_key("experimentError"), result.inspect
    expect(result.fetch("originalUnchanged")).to be(true)
    expect(result.fetch("productionSavingConnected")).to be(false)
    result.fetch("results").each do |candidate|
      expect(candidate.fetch("metadataPreserved")).to be(true)
      expect(candidate.dig("pdf", "pageCount")).to eq(1)
      expect(candidate.fetch("points")).to be <= result.dig("original", "points")
      %w[exponent small_digit dot_and_short].each do |glyph|
        metrics = candidate.dig("pdf", "glyphs").find { |row| row.fetch("name") == glyph }
        expect(metrics.fetch("changedPixels")).to eq(0), "protected glyph changed: #{candidate.fetch('name')} / #{glyph}"
      end
    end
    # Artifacts are opt-in and contain synthetic handwriting only.
    if ENV["DRAFT_SAMPLING_RESULTS_DIR"]
      directory = ENV.fetch("DRAFT_SAMPLING_RESULTS_DIR")
      FileUtils.mkdir_p(directory)
      File.binwrite(File.join(directory, "original-pdf.png"), Base64.decode64(result.delete("originalPdfPng").split(",").last))
      File.binwrite(File.join(directory, "original.png"), Base64.decode64(result.delete("originalPreviewPng").split(",").last))
      result.fetch("results").each do |candidate|
        File.binwrite(File.join(directory, "#{candidate.fetch('name')}-pdf.png"), Base64.decode64(candidate.delete("pdfPng").split(",").last))
        File.binwrite(File.join(directory, "#{candidate.fetch('name')}.png"), Base64.decode64(candidate.delete("previewPng").split(",").last))
      end
      File.write(File.join(directory, "results.json"), JSON.pretty_generate(result))
    end
  end
end
