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

    it "defaults the fade to 10ms" do
      expect(config.fade_ms).to eq(10)
    end

    it "exposes the fade in seconds" do
      expect(config.fade_s).to eq(0.01)
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

    it "defaults the silencedetect noise to -30dB" do
      expect(config.silencedetect_noise).to eq("-30dB")
    end

    it "defaults the silencedetect min duration to 0.1s" do
      expect(config.silencedetect_min_duration).to eq(0.1)
    end

    it "defaults the noise floor to -30dB" do
      expect(config.noise_floor).to eq("-30dB")
    end

    it "defaults the resample rate to 48000Hz" do
      expect(config.resample_rate).to eq(48_000)
    end

    it "defaults the channel layout to stereo" do
      expect(config.channel_layout).to eq("stereo")
    end

    it "defaults the ffmpeg binary to ffmpeg" do
      expect(config.ffmpeg_bin).to eq("ffmpeg")
    end

    it "defaults the ffprobe binary to ffprobe" do
      expect(config.ffprobe_bin).to eq("ffprobe")
    end

    it "defaults volume normalization to on" do
      expect(config.volume_normalize).to be(true)
    end

    it "defaults the normalize target to auto (data-driven median)" do
      expect(config.normalize_target).to eq(:auto)
    end

    it "defaults declicking to on" do
      expect(config.declick).to be(true)
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

    it "honours FADE" do
      expect(build(env: { "FADE" => "20" }).fade_ms).to eq(20)
    end

    it "accepts FADE=0 to disable the fade" do
      expect(build(env: { "FADE" => "0" }).fade_ms).to eq(0)
    end

    it "rejects a negative FADE" do
      expect { build(env: { "FADE" => "-5" }) }
        .to raise_error(CrosstalkCleaner::ConfigurationError, /non-negative integer/)
    end

    it "rejects a non-numeric FADE" do
      expect { build(env: { "FADE" => "fast" }) }
        .to raise_error(CrosstalkCleaner::ConfigurationError, /non-negative integer/)
    end

    it "honours SILENCEDETECT_NOISE" do
      expect(build(env: { "SILENCEDETECT_NOISE" => "-40dB" }).silencedetect_noise).to eq("-40dB")
    end

    it "honours SILENCEDETECT_MIN_DURATION" do
      expect(build(env: { "SILENCEDETECT_MIN_DURATION" => "0.25" }).silencedetect_min_duration).to eq(0.25)
    end

    it "disables declicking for DECLICK=0" do
      expect(build(env: { "DECLICK" => "0" }).declick).to be(false)
    end

    it "keeps declicking on for any other DECLICK value" do
      expect(build(env: { "DECLICK" => "1" }).declick).to be(true)
    end

    it "honours NOISE_FLOOR" do
      expect(build(env: { "NOISE_FLOOR" => "-50dB" }).noise_floor).to eq("-50dB")
    end

    it "honours RESAMPLE_RATE" do
      expect(build(env: { "RESAMPLE_RATE" => "44100" }).resample_rate).to eq(44_100)
    end

    it "honours CHANNEL_LAYOUT" do
      expect(build(env: { "CHANNEL_LAYOUT" => "mono" }).channel_layout).to eq("mono")
    end

    it "honours FFMPEG_BIN" do
      expect(build(env: { "FFMPEG_BIN" => "/opt/ffmpeg" }).ffmpeg_bin).to eq("/opt/ffmpeg")
    end

    it "honours FFPROBE_BIN" do
      expect(build(env: { "FFPROBE_BIN" => "/opt/ffprobe" }).ffprobe_bin).to eq("/opt/ffprobe")
    end

    it "falls back to the default for an empty string value" do
      expect(build(env: { "SILENCEDETECT_NOISE" => "" }).silencedetect_noise).to eq("-30dB")
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

    it "rejects a non-numeric min duration" do
      expect { build(env: { "SILENCEDETECT_MIN_DURATION" => "soon" }) }
        .to raise_error(CrosstalkCleaner::ConfigurationError, /positive number/)
    end

    it "rejects a zero or negative min duration" do
      expect { build(env: { "SILENCEDETECT_MIN_DURATION" => "0" }) }
        .to raise_error(CrosstalkCleaner::ConfigurationError, /positive number/)
    end

    it "disables normalization for VOLUME_NORMALIZE=0" do
      expect(build(env: { "VOLUME_NORMALIZE" => "0" }).volume_normalize).to be(false)
    end

    it "disables normalization for VOLUME_NORMALIZE=false (any case)" do
      expect(build(env: { "VOLUME_NORMALIZE" => "FALSE" }).volume_normalize).to be(false)
    end

    it "keeps normalization on for any other VOLUME_NORMALIZE value" do
      expect(build(env: { "VOLUME_NORMALIZE" => "1" }).volume_normalize).to be(true)
    end

    it "honours a fixed negative NORMALIZE_TARGET" do
      expect(build(env: { "NORMALIZE_TARGET" => "-23" }).normalize_target).to eq(-23.0)
    end

    it "treats NORMALIZE_TARGET=auto (any case) as the data-driven median" do
      expect(build(env: { "NORMALIZE_TARGET" => "AUTO" }).normalize_target).to eq(:auto)
    end

    it "rejects a non-numeric, non-auto NORMALIZE_TARGET" do
      expect { build(env: { "NORMALIZE_TARGET" => "loud" }) }
        .to raise_error(CrosstalkCleaner::ConfigurationError, /must be a number/)
    end
  end
end
