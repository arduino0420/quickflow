require "rails_helper"

RSpec.describe AiFileCleanupJob, type: :job do
  let(:files) { instance_double(OpenAI::Resources::Files) }
  let(:client) { instance_double(OpenAI::Client, files: files) }

  before do
    allow(AiClient).to receive(:build).and_return(client)
    allow(Rails.logger).to receive(:error)
    allow(Rails.logger).to receive(:warn)
  end

  it "deletes a known external file once" do
    allow(files).to receive(:delete).with("file-test").and_return(double(deleted: true))
    described_class.perform_now("file-test")
    expect(files).to have_received(:delete).once
  end

  it "retries a failed deletion without logging response content" do
    allow(files).to receive(:delete).and_raise(Timeout::Error, "PRIVATE API KEY AND ANSWER")
    expect(described_class).to receive(:set).with(wait: 1.minute).and_call_original

    described_class.perform_now("file-test")

    expect(Rails.logger).not_to have_received(:error).with(/PRIVATE/)
    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.any? { |job| job[:job] == described_class }).to be(true)
  end

  it "records final failure without another retry" do
    allow(files).to receive(:delete).and_raise(Timeout::Error, "PRIVATE ANSWER")
    jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size

    described_class.perform_now("file-test", described_class::MAX_ATTEMPTS)

    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(jobs_before)
    expect(Rails.logger).to have_received(:error).with(/file_id=file-test reason=final_delete_error error_class=Timeout::Error/)
    expect(Rails.logger).not_to have_received(:error).with(/PRIVATE/)
  end

  it "retries an unconfirmed deletion response" do
    allow(files).to receive(:delete).and_return(double(deleted: false))
    jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size

    described_class.perform_now("file-test")

    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(jobs_before + 1)
  end

  it "records a rejected retry enqueue" do
    allow(files).to receive(:delete).and_raise(Timeout::Error, "PRIVATE ANSWER")
    allow(described_class).to receive(:set).and_return(double(perform_later: false))

    described_class.perform_now("file-test")

    expect(Rails.logger).to have_received(:error).with(/reason=retry_enqueue_rejected/)
    expect(Rails.logger).not_to have_received(:error).with(/PRIVATE/)
  end

  it "treats an already removed or expired file as a terminal outcome" do
    allow(files).to receive(:delete).and_raise(OpenAI::Errors::NotFoundError.new(
      url: URI("https://api.openai.com/v1/files/file-test"), status: 404, headers: {}, body: {},
      request: nil, response: nil))
    jobs_before = ActiveJob::Base.queue_adapter.enqueued_jobs.size

    described_class.perform_now("file-test")

    expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(jobs_before)
    expect(Rails.logger).to have_received(:warn).with(/file_id=file-test not_found_or_inaccessible/)
  end

  it "records a failed enqueue without exposing an exception message" do
    allow(described_class).to receive(:perform_later).and_raise("PRIVATE API KEY")
    described_class.schedule("file-test")
    expect(Rails.logger).to have_received(:error).with(/file_id=file-test reason=enqueue_error/)
    expect(Rails.logger).not_to have_received(:error).with(/PRIVATE/)
  end
end
