# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe CrosstalkCleaner::Config do
  let(:dir) { Dir.mktmpdir }
  let(:inputs) do
    %w[a.wav b.wav c.wav].map do |name|
      File.join(dir, name).tap { |path| File.write(path, "") }
    end
  end

  after { FileUtils.remove_entry(dir) }

  def build(argv = inputs, env: {})
    described_class.new(argv, env: env)
  end

  describe "input validation" do
    it "keeps the supplied inputs in order" do
      expect(build.inputs).to eq(inputs)
    end

    it "raises when no inputs are given" do
      expect { build([]) }.to raise_error(CrosstalkCleaner::ConfigurationError, /no input files/)
    end

    it "raises when an input file is missing" do
      expect { build([File.join(dir, "missing.wav")]) }
        .to raise_error(CrosstalkCleaner::ConfigurationError, /not found/)
    end
  end

  describe "defaults" do
    subject(:config) { build }

    it "defaults the silence limit to 750ms" do
      expect(config.silence_limit_ms).to eq(750)
    end

    it "defaults the crosstalk tolerance to 300ms" do
      expect(config.crosstalk_tolerance_ms).to eq(300)
    end

    it "defaults the block buffer to 100ms" do
      expect(config.block_buffer_ms).to eq(100)
    end

    it "exposes the block buffer in seconds" do
      expect(config.block_buffer_s).to eq(0.1)
    end

    it "defaults output to output.wav beside the first input" do
      expect(config.output).to eq(File.join(dir, "output.wav"))
    end

    it "exposes tolerance in seconds" do
      expect(config.crosstalk_tolerance_s).to eq(0.3)
    end

    it "exposes the silence limit in seconds" do
      expect(config.silence_limit_s).to eq(0.75)
    end
  end

  describe "environment overrides" do
    it "honours OUTPUT" do
      expect(build(env: { "OUTPUT" => "/tmp/custom.wav" }).output).to eq("/tmp/custom.wav")
    end

    it "ignores an empty OUTPUT" do
      expect(build(env: { "OUTPUT" => "" }).output).to eq(File.join(dir, "output.wav"))
    end

    it "honours SILENCE_LIMIT" do
      expect(build(env: { "SILENCE_LIMIT" => "1500" }).silence_limit_ms).to eq(1500)
    end

    it "honours CROSSTALK_TOLERANCE" do
      expect(build(env: { "CROSSTALK_TOLERANCE" => "500" }).crosstalk_tolerance_ms).to eq(500)
    end

    it "honours BLOCK_BUFFER" do
      expect(build(env: { "BLOCK_BUFFER" => "250" }).block_buffer_ms).to eq(250)
    end

    it "falls back to the default for an empty numeric value" do
      expect(build(env: { "SILENCE_LIMIT" => "" }).silence_limit_ms).to eq(750)
    end

    it "rejects a non-numeric value" do
      expect { build(env: { "SILENCE_LIMIT" => "loud" }) }
        .to raise_error(CrosstalkCleaner::ConfigurationError, /positive integer/)
    end

    it "rejects a zero or negative value" do
      expect { build(env: { "CROSSTALK_TOLERANCE" => "0" }) }
        .to raise_error(CrosstalkCleaner::ConfigurationError, /positive integer/)
    end
  end
end
