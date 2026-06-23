# frozen_string_literal: true

RSpec.describe CrosstalkCleaner::AudioMixer do
  subject(:mixer) { described_class.new(ffmpeg) }

  let(:ffmpeg) { instance_double(CrosstalkCleaner::Ffmpeg) }

  describe "#padded_blocks" do
    subject(:mixer) { described_class.new(ffmpeg, buffer_s: 0.1) }

    it "pads each owned block by the buffer on both sides" do
      expect(mixer.padded_blocks([interval(1.0, 2.0, 0)])).to eq([[0.9, 2.1]])
    end

    it "clamps the padded start at zero so it never goes negative" do
      expect(mixer.padded_blocks([interval(0.05, 2.0, 0)])).to eq([[0.0, 2.1]])
    end

    it "returns nothing for a track that owns no time" do
      expect(mixer.padded_blocks([])).to eq([])
    end

    it "merges blocks whose padding overlaps and sorts by time" do
      blocks = mixer.padded_blocks([interval(4.0, 5.0, 0), interval(1.0, 2.0, 0), interval(2.15, 3.0, 0)])
      expect(blocks).to eq([[0.9, 3.1], [3.9, 5.1]])
    end
  end

  describe "#filter_complex" do
    it "trims each track to the audio it owns and sums them, silencing empty tracks" do
      ownership = { 0 => [interval(0.0, 5.0, 0)], 1 => [] }
      expect(mixer.filter_complex(2, ownership)).to eq(
        "[0:a]aresample=48000,aformat=channel_layouts=stereo," \
        "atrim=start=0.000:end=5.000,asetpts=PTS-STARTPTS[a0];" \
        "[1:a]aresample=48000,aformat=channel_layouts=stereo,volume=0[a1];" \
        "[a0][a1]amix=inputs=2:normalize=0[mix]"
      )
    end

    it "honours a custom resample rate and channel layout" do
      mixer = described_class.new(ffmpeg, resample_rate: 44_100, channel_layout: "mono")
      ownership = { 0 => [interval(0.0, 5.0, 0)] }
      expect(mixer.filter_complex(1, ownership)).to eq(
        "[0:a]aresample=44100,aformat=channel_layouts=mono," \
        "atrim=start=0.000:end=5.000,asetpts=PTS-STARTPTS[a0];" \
        "[a0]amix=inputs=1:normalize=0[mix]"
      )
    end

    it "applies a per-track normalization gain after the trim" do
      ownership = { 0 => [interval(0.0, 5.0, 0)], 1 => [interval(0.0, 5.0, 1)] }
      expect(mixer.filter_complex(2, ownership, { 0 => 2.5, 1 => -4.0 })).to eq(
        "[0:a]aresample=48000,aformat=channel_layouts=stereo," \
        "atrim=start=0.000:end=5.000,asetpts=PTS-STARTPTS,volume=2.50dB[a0];" \
        "[1:a]aresample=48000,aformat=channel_layouts=stereo," \
        "atrim=start=0.000:end=5.000,asetpts=PTS-STARTPTS,volume=-4.00dB[a1];" \
        "[a0][a1]amix=inputs=2:normalize=0[mix]"
      )
    end

    it "omits the gain filter for tracks with no (or zero) gain" do
      ownership = { 0 => [interval(0.0, 5.0, 0)] }
      expect(mixer.filter_complex(1, ownership, { 0 => 0.0 })).to eq(
        "[0:a]aresample=48000,aformat=channel_layouts=stereo," \
        "atrim=start=0.000:end=5.000,asetpts=PTS-STARTPTS[a0];" \
        "[a0]amix=inputs=1:normalize=0[mix]"
      )
    end

    context "when a block starts after zero" do
      subject(:mixer) { described_class.new(ffmpeg, buffer_s: 0.1, fade_s: 0.01) }

      it "splits into a muted lead-in gap and a faded block, then concats them" do
        ownership = { 0 => [interval(1.0, 2.0, 0)], 1 => [] }
        expect(mixer.filter_complex(2, ownership)).to eq(
          "[0:a]aresample=48000,aformat=channel_layouts=stereo,asplit=2[t0_in0][t0_in1];" \
          "[t0_in0]atrim=start=0.000:end=0.900,asetpts=PTS-STARTPTS,volume=0[t0_seg0];" \
          "[t0_in1]atrim=start=0.900:end=2.100,asetpts=PTS-STARTPTS," \
          "afade=t=in:st=0.000:d=0.010,afade=t=out:st=1.190:d=0.010[t0_seg1];" \
          "[t0_seg0][t0_seg1]concat=n=2:v=0:a=1[a0];" \
          "[1:a]aresample=48000,aformat=channel_layouts=stereo,volume=0[a1];" \
          "[a0][a1]amix=inputs=2:normalize=0[mix]"
        )
      end

      it "tiles multiple blocks with gaps and applies the gain to the whole track" do
        ownership = { 0 => [interval(1.0, 2.0, 0), interval(4.0, 5.0, 0)] }
        expect(mixer.filter_complex(1, ownership, { 0 => 2.5 })).to eq(
          "[0:a]aresample=48000,aformat=channel_layouts=stereo,asplit=4" \
          "[t0_in0][t0_in1][t0_in2][t0_in3];" \
          "[t0_in0]atrim=start=0.000:end=0.900,asetpts=PTS-STARTPTS,volume=0[t0_seg0];" \
          "[t0_in1]atrim=start=0.900:end=2.100,asetpts=PTS-STARTPTS," \
          "afade=t=in:st=0.000:d=0.010,afade=t=out:st=1.190:d=0.010[t0_seg1];" \
          "[t0_in2]atrim=start=2.100:end=3.900,asetpts=PTS-STARTPTS,volume=0[t0_seg2];" \
          "[t0_in3]atrim=start=3.900:end=5.100,asetpts=PTS-STARTPTS," \
          "afade=t=in:st=0.000:d=0.010,afade=t=out:st=1.190:d=0.010[t0_seg3];" \
          "[t0_seg0][t0_seg1][t0_seg2][t0_seg3]concat=n=4:v=0:a=1,volume=2.50dB[a0];" \
          "[a0]amix=inputs=1:normalize=0[mix]"
        )
      end
    end

    context "with fading disabled" do
      subject(:mixer) { described_class.new(ffmpeg, fade_s: 0.0) }

      it "hard-cuts each block without an afade" do
        ownership = { 0 => [interval(1.0, 2.0, 0)] }
        expect(mixer.filter_complex(1, ownership)).to eq(
          "[0:a]aresample=48000,aformat=channel_layouts=stereo,asplit=2[t0_in0][t0_in1];" \
          "[t0_in0]atrim=start=0.000:end=1.000,asetpts=PTS-STARTPTS,volume=0[t0_seg0];" \
          "[t0_in1]atrim=start=1.000:end=2.000,asetpts=PTS-STARTPTS[t0_seg1];" \
          "[t0_seg0][t0_seg1]concat=n=2:v=0:a=1[a0];" \
          "[a0]amix=inputs=1:normalize=0[mix]"
        )
      end
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
      expect(script_contents).to include("atrim=start=9998.000:end=9999.000")
    end
  end
end
