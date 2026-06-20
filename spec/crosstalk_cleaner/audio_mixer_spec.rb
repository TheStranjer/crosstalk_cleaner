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
    it "lays out inputs, the filtergraph script, the map and the output" do
      args = mixer.build_args(["a.wav"], "/tmp/filter.txt", "out.wav")
      expect(args).to eq([
                           "-i", "a.wav",
                           "-filter_complex_script", "/tmp/filter.txt",
                           "-map", "[mix]", "out.wav"
                         ])
    end
  end

  describe "#render" do
    it "runs ffmpeg and returns the output path" do
      ownership = { 0 => [interval(0.0, 5.0, 0)] }
      allow(ffmpeg).to receive(:run)

      expect(mixer.render(["a.wav"], ownership, "out.wav")).to eq("out.wav")
      expect(ffmpeg).to have_received(:run)
    end

    # Regression: a recording with thousands of speech intervals used to inline
    # the whole filtergraph into argv and blow the OS limit (Errno::E2BIG). The
    # filtergraph must travel via a script file so argv stays tiny.
    it "keeps argv small by passing the filtergraph through a script file" do
      ownership = { 0 => Array.new(5000) { |i| interval(i * 2.0, (i * 2.0) + 1.0, 0) } }
      captured_args = nil
      script_contents = nil
      allow(ffmpeg).to receive(:run) do |args|
        captured_args = args
        script_path = args[args.index("-filter_complex_script") + 1]
        script_contents = File.read(script_path)
      end

      mixer.render(["a.wav"], ownership, "out.wav")

      expect(captured_args).not_to include("-filter_complex")
      expect(captured_args.join(" ").length).to be < 1_000
      expect(script_contents).to include("amix=inputs=1:normalize=0[mix]")
      expect(script_contents).to include("between(t,9998.000,9999.000)")
    end
  end
end
