# frozen_string_literal: true

RSpec.describe CrosstalkCleaner::AudioMixer do
  subject(:mixer) { described_class.new(ffmpeg) }

  let(:ffmpeg) { instance_double(CrosstalkCleaner::Ffmpeg) }

  describe "#mute_expression" do
    it "mutes everything for a track that owns no time" do
      expect(mixer.mute_expression([])).to eq("1")
    end

    it "mutes outside the owned intervals" do
      expr = mixer.mute_expression([interval(1.0, 2.0, 0), interval(4.0, 5.5, 0)])
      expect(expr).to eq("not(between(t,1.000,2.000)+between(t,4.000,5.500))")
    end
  end

  describe "#filter_complex" do
    it "builds one muted chain per track and sums them" do
      ownership = { 0 => [interval(0.0, 5.0, 0)], 1 => [] }
      expect(mixer.filter_complex(2, ownership)).to eq(
        "[0:a]aresample=48000,aformat=channel_layouts=stereo," \
        "volume=0:enable='not(between(t,0.000,5.000))'[a0];" \
        "[1:a]aresample=48000,aformat=channel_layouts=stereo," \
        "volume=0:enable='1'[a1];" \
        "[a0][a1]amix=inputs=2:normalize=0[mix]"
      )
    end
  end

  describe "#build_args" do
    it "lays out inputs, the filtergraph, the map and the output" do
      ownership = { 0 => [interval(0.0, 5.0, 0)] }
      args = mixer.build_args(["a.wav"], ownership, "out.wav")
      expect(args).to eq([
                           "-i", "a.wav",
                           "-filter_complex",
                           "[0:a]aresample=48000,aformat=channel_layouts=stereo," \
                           "volume=0:enable='not(between(t,0.000,5.000))'[a0];" \
                           "[a0]amix=inputs=1:normalize=0[mix]",
                           "-map", "[mix]", "out.wav"
                         ])
    end
  end

  describe "#render" do
    it "runs ffmpeg and returns the output path" do
      ownership = { 0 => [interval(0.0, 5.0, 0)] }
      expected = mixer.build_args(["a.wav"], ownership, "out.wav")
      allow(ffmpeg).to receive(:run)

      expect(mixer.render(["a.wav"], ownership, "out.wav")).to eq("out.wav")
      expect(ffmpeg).to have_received(:run).with(expected)
    end
  end
end
