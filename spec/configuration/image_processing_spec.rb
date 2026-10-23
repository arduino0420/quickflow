require "spec_helper"
require "bundler/setup"
require "open3"
require "tempfile"
require "active_support/all"
require "active_storage"
require "active_storage/transformers/transformer"
require "active_storage/transformers/image_processing_transformer"

RSpec.describe "Image processing backends" do
  it "keeps both backend gems lazy until explicitly required" do
    output, error, status = Open3.capture3("bundle", "exec", "ruby", "-e", <<~'SCRIPT')
      require "bundler/setup"
      Bundler.require(:default)
      abort "eager backend load" if defined?(Vips) || defined?(MiniMagick)
      require "image_processing/mini_magick"
      abort "missing MiniMagick backend" unless defined?(ImageProcessing::MiniMagick)
    SCRIPT
    expect(status.success?).to be(true), output + error
  end

  it "processes a synthetic image through the Rails Vips transformer" do
    require "active_storage/transformers/vips"

    Tempfile.create([ "quickflow-synthetic", ".png" ]) do |source|
      Vips::Image.black(32, 24).new_from_image([ 40, 120, 200 ]).write_to_file(source.path)
      transformer = ActiveStorage::Transformers::Vips.new(resize_to_limit: [ 16, 16 ])
      transformer.transform(source, format: "png") do |result|
        image = Vips::Image.new_from_file(result.path)
        expect([ image.width, image.height, image.bands ]).to eq([ 16, 12, 3 ])
        expect(image.getpoint(8, 6)).to eq([ 40.0, 120.0, 200.0 ])
      end
    end
  end
end
