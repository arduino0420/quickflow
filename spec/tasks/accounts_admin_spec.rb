require "rails_helper"
require "rake"

RSpec.describe "Operator admin provisioning" do
  let(:school) { School.create!(school_code: "ADMINA") }
  let(:task) { Rake::Task["accounts:create_admin"] }

  before do
    Rails.application.load_tasks unless Rake::Task.task_defined?("accounts:create_admin")
    task.reenable
    allow(STDIN).to receive(:tty?).and_return(true)
    allow(STDIN).to receive(:noecho).and_yield
    allow($stdout).to receive(:print)
    allow($stdout).to receive(:puts)
  end

  def inputs(code: "ADMINA", user_id: "provisioned-admin", password: "Long River 8 Beacon 42", confirmation: password)
    school
    allow(STDIN).to receive(:gets).and_return("y\n", "#{code}\n", "#{user_id}\n", "#{password}\n", "#{confirmation}\n")
  end

  it "creates only an admin, hides passwords and does not grant teacher authentication" do
    inputs
    original = [ School, Teacher, Classroom, Student ].to_h { |model| [ model, model.order(:id).map(&:attributes) ] }
    logs = StringIO.new
    original_logger = ActiveRecord::Base.logger
    begin
      ActiveRecord::Base.logger = ActiveSupport::Logger.new(logs)
      expect { task.invoke }.to change(Admin, :count).by(1)
    ensure
      ActiveRecord::Base.logger = original_logger
    end
    admin = Admin.find_by!(user_id: "provisioned-admin")
    expect(admin.school).to eq(school)
    expect(admin.authenticate("Long River 8 Beacon 42")).to eq(admin)
    expect(STDIN).to have_received(:noecho).twice
    expect($stdout).not_to have_received(:puts).with(/Long River 8 Beacon 42/)
    expect($stdout).not_to have_received(:print).with(/Long River 8 Beacon 42/)
    expect(logs.string).not_to include("Long River 8 Beacon 42", admin.password_digest)
    original.each { |model, records| expect(model.order(:id).map(&:attributes)).to eq(records) }

    session = ActionDispatch::Integration::Session.new(Rails.application)
    session.post("/login", params: { session: { user_id: admin.user_id, password: "Long River 8 Beacon 42" } })
    expect(session.response.status).to eq(422)
    session.get("/assignments")
    expect(session.response.status).to eq(303)
    expect(URI(session.response.location).path).to eq("/login")
  end

  it "allows a different existing school after operator verification" do
    other_school = School.create!(school_code: "ADMINB")
    inputs(code: other_school.school_code)

    expect { task.invoke }.to change(Admin, :count).by(1)
    expect(Admin.last.school).to eq(other_school)
  end

  [ { password: "", confirmation: "" }, { confirmation: "different" }, { confirmation: "" },
    { password: "a" * 73 }, { password: "short" }, { password: "password123456789" },
    { user_id: "" }, { user_id: " " } ].each do |change|
    it "rejects invalid admin input #{change.keys.inspect}: #{change.values.map(&:length)}" do
      inputs(**change)

      expect { expect { task.invoke }.to raise_error(SystemExit) }.not_to change(Admin, :count)
    end
  end

  it "rejects a duplicate ID without changing the original admin" do
    inputs
    existing = Admin.create!(school: school, user_id: "provisioned-admin", password: "existing-admin-password")
    original = existing.attributes

    expect { expect { task.invoke }.to raise_error(SystemExit) }.not_to change(Admin, :count)
    expect(existing.reload.attributes).to eq(original)
  end

  it "handles a database uniqueness race without retaining an admin" do
    inputs
    allow_any_instance_of(Admin).to receive(:save).and_raise(ActiveRecord::RecordNotUnique)

    expect { expect { task.invoke }.to raise_error(SystemExit) }.not_to change(Admin, :count)
  end

  [ "UNKNOWN", "" ].each do |code|
    it "rejects an unknown or empty school code without creating schools or admins: #{code.inspect}" do
      inputs(code: code)
      original_schools = School.count

      expect { expect { task.invoke }.to raise_error(SystemExit) }.not_to change(Admin, :count)
      expect(School.count).to eq(original_schools)
      expect(STDIN).not_to have_received(:noecho)
    end
  end

  it "refuses provisioning without operator confirmation" do
    allow(STDIN).to receive(:gets).and_return("n\n")

    expect { expect { task.invoke }.to raise_error(SystemExit) }.not_to change(Admin, :count)
    expect(STDIN).not_to have_received(:noecho)
  end

  it "refuses noninteractive execution before reading any input" do
    allow(STDIN).to receive(:tty?).and_return(false)
    expect(STDIN).not_to receive(:gets)

    expect { expect { task.invoke }.to raise_error(SystemExit) }.not_to change(Admin, :count)
    expect(STDIN).not_to have_received(:noecho)
  end
end
