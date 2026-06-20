# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../../crosstalk_cleaner"

RSpec.describe CrosstalkCleaner::CLI do
  let(:out) { StringIO.new }
  let(:err) { StringIO.new }
  let(:dir) { Dir.mktmpdir }
  let(:input) { File.join(dir, "a.wav").tap { |path| File.write(path, "") } }

  after { FileUtils.remove_entry(dir) }

  it "runs the pipeline and returns a zero exit status" do
    fake = instance_double(CrosstalkCleaner::Cleaner, run: "/tmp/out.wav")
    allow(CrosstalkCleaner::Cleaner).to receive(:new).and_return(fake)

    status = described_class.run([input], env: {}, logger: out, error_logger: err)

    expect(status).to eq(0)
    expect(fake).to have_received(:run)
  end

  it "reports configuration errors and returns a non-zero exit status" do
    status = described_class.run([], env: {}, logger: out, error_logger: err)

    expect(status).to eq(1)
    expect(err.string).to include("crosstalk_cleaner: no input files given")
  end
end
