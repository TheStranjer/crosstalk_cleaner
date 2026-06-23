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
    allow(ffmpeg).to receive_messages(duration: 10.0, run: true, ebur128: "I: -20.0 LUFS")
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

    context "with a fixed normalize target" do
      let(:config) { CrosstalkCleaner::Config.new([input_a, input_b], env: { "NORMALIZE_TARGET" => "-16" }) }

      it "measures and logs a normalization gain for the owning track" do
        cleaner.run
        expect(ffmpeg).to have_received(:ebur128).with(input_a, anything)
        # a.wav owns the whole timeline and measured -20 LUFS, so +4 dB to hit -16.
        expect(logger.string).to include("track 0 gain +4.00 dB")
      end
    end

    context "when normalization is disabled" do
      let(:config) { CrosstalkCleaner::Config.new([input_a, input_b], env: { "VOLUME_NORMALIZE" => "0" }) }

      it "never measures loudness and leaves levels untouched" do
        cleaner.run
        expect(ffmpeg).not_to have_received(:ebur128)
        expect(logger.string).not_to include("Normalizing")
      end
    end
  end
end
