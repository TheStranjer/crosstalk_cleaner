# frozen_string_literal: true

require "tempfile"

RSpec.describe CrosstalkCleaner::GainEnvelope do
  # Renders the envelope to a temp file and reads the raw float samples back, so
  # the test exercises the real on-disk output. A rate of 1000 Hz makes one sample
  # one millisecond, keeping the arithmetic easy to reason about.
  def samples_for(envelope, intervals, duration_s)
    Tempfile.create(["env", ".f32"]) do |file|
      file.close
      envelope.write(file.path, intervals, duration_s)
      File.binread(file.path).unpack("e*")
    end
  end

  describe "#write" do
    it "marks an owned interval at full gain and the rest silent" do
      envelope = described_class.new(resample_rate: 1000)
      samples = samples_for(envelope, [interval(0.2, 0.5, 0)], 1.0)

      expect(samples.length).to eq(1000)
      expect(samples[100]).to eq(0.0)
      expect(samples[200]).to eq(1.0)
      expect(samples[499]).to eq(1.0)
      expect(samples[500]).to eq(0.0)
      expect(samples[800]).to eq(0.0)
    end

    it "pads each owned block by the buffer on both sides" do
      envelope = described_class.new(resample_rate: 1000, buffer_s: 0.1)
      samples = samples_for(envelope, [interval(0.3, 0.5, 0)], 1.0)

      expect(samples[199]).to eq(0.0)
      expect(samples[200]).to eq(1.0) # 0.3 - 0.1 buffer
      expect(samples[599]).to eq(1.0) # 0.5 + 0.1 buffer
      expect(samples[600]).to eq(0.0)
    end

    it "eases in and out with a raised-cosine ramp" do
      envelope = described_class.new(resample_rate: 1000, fade_s: 0.01)
      samples = samples_for(envelope, [interval(0.1, 0.5, 0)], 1.0)

      expect(samples[100]).to be_within(1e-6).of(0.0)   # ramp start
      expect(samples[105]).to be_within(1e-6).of(0.5)   # mid ramp-in
      expect(samples[200]).to eq(1.0)                   # interior
      expect(samples[499]).to be_within(1e-6).of(0.0)   # ramp end
      expect(samples[500]).to eq(0.0)
    end

    it "merges blocks whose padding overlaps into one" do
      envelope = described_class.new(resample_rate: 1000, buffer_s: 0.1)
      samples = samples_for(envelope, [interval(0.2, 0.4, 0), interval(0.5, 0.7, 0)], 1.0)

      # Padded to [0.1, 0.5) and [0.4, 0.8); they touch and merge, so the gap
      # between the original intervals stays at full gain.
      expect(samples[450]).to eq(1.0)
    end

    it "stays continuous across the chunk boundary" do
      stub_const("#{described_class}::CHUNK_SAMPLES", 64)
      envelope = described_class.new(resample_rate: 1000)
      samples = samples_for(envelope, [interval(0.05, 0.15, 0)], 0.2)

      expect(samples.length).to eq(200)
      [63, 64, 127, 128].each { |i| expect(samples[i]).to eq(1.0) }
    end
  end
end
