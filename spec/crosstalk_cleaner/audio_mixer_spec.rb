# frozen_string_literal: true

RSpec.describe CrosstalkCleaner::AudioMixer do
  subject(:mixer) { described_class.new(ffmpeg) }

  let(:ffmpeg) { instance_double(CrosstalkCleaner::Ffmpeg) }

  describe "#filter_complex" do
    it "multiplies each track by its envelope input and sums them, muting empty tracks" do
      ownership = { 0 => [interval(1.0, 2.0, 0)], 1 => [] }
      expect(mixer.filter_complex(2, ownership)).to eq(
        "[0:a]aresample=48000,aformat=channel_layouts=stereo[trk0];" \
        "[2:a]aresample=48000,pan=stereo|c0=c0|c1=c0[env0];" \
        "[trk0][env0]amultiply[a0];" \
        "[1:a]aresample=48000,aformat=channel_layouts=stereo,volume=0[a1];" \
        "[a0][a1]amix=inputs=2:normalize=0[mix]"
      )
    end

    it "assigns one envelope input per owning track, after the track inputs" do
      ownership = { 0 => [interval(0.0, 5.0, 0)], 1 => [interval(0.0, 5.0, 1)] }
      expect(mixer.filter_complex(2, ownership)).to eq(
        "[0:a]aresample=48000,aformat=channel_layouts=stereo[trk0];" \
        "[2:a]aresample=48000,pan=stereo|c0=c0|c1=c0[env0];" \
        "[trk0][env0]amultiply[a0];" \
        "[1:a]aresample=48000,aformat=channel_layouts=stereo[trk1];" \
        "[3:a]aresample=48000,pan=stereo|c0=c0|c1=c0[env1];" \
        "[trk1][env1]amultiply[a1];" \
        "[a0][a1]amix=inputs=2:normalize=0[mix]"
      )
    end

    it "honours a custom resample rate and channel layout" do
      mixer = described_class.new(ffmpeg, resample_rate: 44_100, channel_layout: "mono")
      ownership = { 0 => [interval(0.0, 5.0, 0)] }
      expect(mixer.filter_complex(1, ownership)).to eq(
        "[0:a]aresample=44100,aformat=channel_layouts=mono[trk0];" \
        "[1:a]aresample=44100,pan=mono|c0=c0[env0];" \
        "[trk0][env0]amultiply[a0];" \
        "[a0]amix=inputs=1:normalize=0[mix]"
      )
    end

    it "applies a per-track normalization gain after the multiply" do
      ownership = { 0 => [interval(0.0, 5.0, 0)], 1 => [interval(0.0, 5.0, 1)] }
      expect(mixer.filter_complex(2, ownership, { 0 => 2.5, 1 => -4.0 })).to eq(
        "[0:a]aresample=48000,aformat=channel_layouts=stereo[trk0];" \
        "[2:a]aresample=48000,pan=stereo|c0=c0|c1=c0[env0];" \
        "[trk0][env0]amultiply,volume=2.50dB[a0];" \
        "[1:a]aresample=48000,aformat=channel_layouts=stereo[trk1];" \
        "[3:a]aresample=48000,pan=stereo|c0=c0|c1=c0[env1];" \
        "[trk1][env1]amultiply,volume=-4.00dB[a1];" \
        "[a0][a1]amix=inputs=2:normalize=0[mix]"
      )
    end

    it "omits the gain filter for tracks with no (or zero) gain" do
      ownership = { 0 => [interval(0.0, 5.0, 0)] }
      expect(mixer.filter_complex(1, ownership, { 0 => 0.0 })).to eq(
        "[0:a]aresample=48000,aformat=channel_layouts=stereo[trk0];" \
        "[1:a]aresample=48000,pan=stereo|c0=c0|c1=c0[env0];" \
        "[trk0][env0]amultiply[a0];" \
        "[a0]amix=inputs=1:normalize=0[mix]"
      )
    end
  end

  describe "#build_args" do
    it "lays out track inputs, the raw-float envelope inputs, the script, map and output" do
      args = mixer.build_args(["a.wav"], ["/tmp/env0.f32"], "/tmp/filter.txt", "out.wav")
      expect(args).to eq([
                           "-i", "a.wav",
                           "-f", "f32le", "-ar", "1000", "-ac", "1", "-i", "/tmp/env0.f32",
                           "-filter_complex_script", "/tmp/filter.txt",
                           "-map", "[mix]", "out.wav"
                         ])
    end

    it "declares the envelope inputs at the low envelope rate regardless of the mix rate" do
      mixer = described_class.new(ffmpeg, resample_rate: 44_100)
      args = mixer.build_args(["a.wav"], ["/tmp/env0.f32"], "/tmp/filter.txt", "out.wav")
      expect(args).to include("-ar", "1000")
      expect(args).not_to include("44100")
    end
  end

  describe "#render" do
    it "runs ffmpeg and returns the output path" do
      ownership = { 0 => [interval(0.0, 5.0, 0)] }
      allow(ffmpeg).to receive_messages(duration: 5.0, run: true)

      expect(mixer.render(["a.wav"], ownership, "out.wav")).to eq("out.wav")
      expect(ffmpeg).to have_received(:run)
    end

    it "feeds ffmpeg one envelope input per owning track" do
      ownership = { 0 => [interval(0.0, 5.0, 0)], 1 => [] }
      allow(ffmpeg).to receive(:duration).and_return(5.0)
      captured_args = nil
      allow(ffmpeg).to receive(:run) { |args| captured_args = args }

      mixer.render(["a.wav", "b.wav"], ownership, "out.wav")

      expect(captured_args.count("-i")).to eq(3) # two tracks + one envelope (track 1 owns nothing)
      expect(captured_args).to include("f32le")
    end

    # Regression: the block buffer must never pad a track over a region another
    # track owns -- doing so unmutes both tracks at the boundary and plays back the
    # very bleed the crosstalk pass removed. Adjacent owners meet at the boundary;
    # neither one's buffer crosses it.
    it "never lets a track's buffer bleed into a region another track owns" do
      mixer = described_class.new(ffmpeg, buffer_s: 0.1)
      ownership = { 0 => [interval(0.0, 4.0, 0)], 1 => [interval(4.0, 8.0, 1)] }
      allow(ffmpeg).to receive(:duration).and_return(8.0)
      envelopes = nil
      allow(ffmpeg).to receive(:run) do |args|
        env_paths = args.grep(/\.f32\z/)
        envelopes = env_paths.map { |path| File.binread(path).unpack("e*") }
      end

      mixer.render(["a.wav", "b.wav"], ownership, "out.wav")

      env0, env1 = envelopes
      # At the boundary (t = 4.0s, sample 4000 at the 1000 Hz envelope rate) only
      # one track may be live; with the bug both were.
      expect(env0[4000]).to eq(0.0) # track 0 stops at the boundary, not 0.1s past it
      expect(env1[3999]).to eq(0.0) # track 1 starts at the boundary, not 0.1s before it
      expect(env0[3999]).to be > 0.0
      expect(env1[4000]).to be > 0.0
    end

    # Regression: the interval data now travels in the binary envelope, never the
    # filtergraph, so a track owning thousands of blocks keeps both argv and the
    # filtergraph script tiny (it used to inline the whole graph and blow E2BIG).
    it "keeps argv and the filtergraph small no matter how many intervals a track owns" do
      mixer = described_class.new(ffmpeg, resample_rate: 1000)
      ownership = { 0 => Array.new(5000) { |i| interval(i * 2.0, (i * 2.0) + 1.0, 0) } }
      allow(ffmpeg).to receive_messages(duration: 5.0, run: true)
      captured_args = nil
      script_contents = nil
      allow(ffmpeg).to receive(:run) do |args|
        captured_args = args
        script_contents = File.read(args[args.index("-filter_complex_script") + 1])
      end

      mixer.render(["a.wav"], ownership, "out.wav")

      expect(captured_args).not_to include("-filter_complex")
      expect(captured_args.join(" ").length).to be < 1_000
      expect(script_contents).to include("amultiply")
      expect(script_contents).to include("amix=inputs=1:normalize=0[mix]")
      expect(script_contents).not_to include("between(")
    end
  end
end
