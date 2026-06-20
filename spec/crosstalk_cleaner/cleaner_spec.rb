# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "stringio"

RSpec.describe CrosstalkCleaner::Cleaner do
  subject(:cleaner) { described_class.new(config, ffmpeg: ffmpeg, logger: logger) }

  let(:ffmpeg) { instance_double(CrosstalkCleaner::Ffmpeg) }
  let(:logger) { StringIO.new }
  let(:dir) { Dir.mktmpdir }
  let(:input_a) { File.join(dir, "a.wav") }
  let(:input_b) { File.join(dir, "b.wav") }
  let(:config) { CrosstalkCleaner::Config.new([input_a, input_b], env: {}) }

  after { FileUtils.remove_entry(dir) }

  before do
    [input_a, input_b].each { |path| File.write(path, "") }
    allow(ffmpeg).to receive_messages(duration: 10.0, run: true)
    # a.wav speaks the whole time; b.wav only speaks from 5s on (silent 0-5).
    allow(ffmpeg).to receive(:silencedetect).with(input_a).and_return("")
    allow(ffmpeg).to receive(:silencedetect).with(input_b).and_return("silence_start: 0.0\nsilence_end: 5.0")
  end

  describe "#resolve_ownership" do
    it "gives the whole timeline to the earlier speaker, grouped by track" do
      expect(cleaner.resolve_ownership).to eq(0 => [interval(0.0, 10.0, 0)])
    end
  end

  describe "#run" do
    it "renders the crosstalk mix then strips silence and returns the output path" do
      expect(cleaner.run).to eq(config.output)
      expect(ffmpeg).to have_received(:run).twice
    end

    it "logs each stage of the pipeline" do
      cleaner.run
      log = logger.string
      expect(log).to include("Detecting speech on #{input_a}")
      expect(log).to include("Collapsing 2 tracks")
      expect(log).to include("Removing dead silence")
      expect(log).to include("Wrote #{config.output}")
    end
  end
end
