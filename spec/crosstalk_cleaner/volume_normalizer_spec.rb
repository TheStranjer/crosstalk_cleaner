# frozen_string_literal: true

RSpec.describe CrosstalkCleaner::VolumeNormalizer do
  subject(:normalizer) { described_class.new(ffmpeg, target: -16.0) }

  let(:ffmpeg) { instance_double(CrosstalkCleaner::Ffmpeg) }

  # A trimmed-down ebur128 stderr summary reporting an integrated loudness of +lufs+.
  def summary(lufs)
    "[Parsed_ebur128_0 @ 0x0] t: 1   M: -20.0 S: -20.0     I: -99.0 LUFS\n" \
      "[Parsed_ebur128_0 @ 0x0] Summary:\n\n  Integrated loudness:\n    I:   #{lufs} LUFS\n    Threshold: -28.0 LUFS"
  end

  describe "#gains" do
    it "returns the dB needed to bring each track to the target" do
      allow(ffmpeg).to receive(:ebur128).with("a.wav", anything).and_return(summary(-21.0))
      allow(ffmpeg).to receive(:ebur128).with("b.wav", anything).and_return(summary(-12.0))

      ownership = { 0 => [interval(0.0, 5.0, 0)], 1 => [interval(0.0, 5.0, 1)] }
      expect(normalizer.gains(%w[a.wav b.wav], ownership)).to eq(0 => 5.0, 1 => -4.0)
    end

    it "skips a track that owns no audio without measuring it" do
      allow(ffmpeg).to receive(:ebur128).and_return(summary(-16.0))
      gains = normalizer.gains(%w[a.wav b.wav], { 0 => [interval(0.0, 5.0, 0)], 1 => [] })

      expect(gains).not_to have_key(1)
      expect(ffmpeg).not_to have_received(:ebur128).with("b.wav", anything)
    end

    it "skips a track that measures as silent (-inf)" do
      allow(ffmpeg).to receive(:ebur128).and_return(summary("-inf"))
      expect(normalizer.gains(%w[a.wav], { 0 => [interval(0.0, 5.0, 0)] })).to eq({})
    end

    it "clamps an extreme boost to the maximum boost" do
      allow(ffmpeg).to receive(:ebur128).and_return(summary(-70.0))
      expect(normalizer.gains(%w[a.wav], { 0 => [interval(0.0, 5.0, 0)] })).to eq(0 => 15.0)
    end

    it "clamps a cut so a too-loud track is never crushed" do
      allow(ffmpeg).to receive(:ebur128).and_return(summary(-4.0))
      expect(normalizer.gains(%w[a.wav], { 0 => [interval(0.0, 5.0, 0)] })).to eq(0 => -6.0)
    end

    it "skips a track that owns too little audio to measure reliably" do
      allow(ffmpeg).to receive(:ebur128).and_return(summary(-20.0))
      gains = normalizer.gains(%w[a.wav], { 0 => [interval(0.0, 2.0, 0)] })

      expect(gains).to eq({})
      expect(ffmpeg).not_to have_received(:ebur128)
    end
  end

  describe "#gains with an auto (median) target" do
    subject(:normalizer) { described_class.new(ffmpeg, target: :auto) }

    it "levels every track toward the median of the measured loudnesses" do
      allow(ffmpeg).to receive(:ebur128).with("a.wav", anything).and_return(summary(-21.0))
      allow(ffmpeg).to receive(:ebur128).with("b.wav", anything).and_return(summary(-16.0))
      allow(ffmpeg).to receive(:ebur128).with("c.wav", anything).and_return(summary(-14.0))

      ownership = (0..2).to_h { |i| [i, [interval(0.0, 5.0, i)]] }
      expect(normalizer.gains(%w[a.wav b.wav c.wav], ownership)).to eq(0 => 5.0, 1 => 0.0, 2 => -2.0)
    end
  end

  describe "#measure" do
    subject(:normalizer) { described_class.new(ffmpeg, target: -16.0, buffer_s: 0.1) }

    it "selects only the buffered owned intervals when measuring" do
      allow(ffmpeg).to receive(:ebur128).and_return(summary(-18.0))
      normalizer.measure("a.wav", [interval(1.0, 2.0, 0)])

      expect(ffmpeg).to have_received(:ebur128).with("a.wav", "between(t,0.900,2.100)")
    end

    it "takes the integrated value from the final summary, not a running frame" do
      allow(ffmpeg).to receive(:ebur128).and_return(summary(-18.0))
      expect(normalizer.measure("a.wav", [interval(1.0, 2.0, 0)])).to eq(-18.0)
    end
  end
end
