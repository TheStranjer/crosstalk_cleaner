# frozen_string_literal: true

RSpec.describe CrosstalkCleaner::SilenceRemover do
  subject(:remover) { described_class.new(ffmpeg) }

  let(:ffmpeg) { instance_double(CrosstalkCleaner::Ffmpeg) }

  describe "#silence_filter" do
    it "keeps at most the given amount of silence" do
      expect(remover.silence_filter(0.75))
        .to eq("silenceremove=stop_periods=-1:stop_duration=0.750:stop_threshold=-30dB")
    end

    it "uses the configured noise floor as the threshold" do
      quiet = described_class.new(ffmpeg, noise_floor: "-50dB")
      expect(quiet.silence_filter(0.75))
        .to eq("silenceremove=stop_periods=-1:stop_duration=0.750:stop_threshold=-50dB")
    end
  end

  describe "#build_args" do
    it "wires the input, filter and output" do
      expect(remover.build_args("in.wav", "out.wav", 1.5)).to eq([
                                                                   "-i", "in.wav",
                                                                   "-af",
                                                                   "silenceremove=stop_periods=-1:" \
                                                                   "stop_duration=1.500:stop_threshold=-30dB",
                                                                   "out.wav"
                                                                 ])
    end
  end

  describe "#render" do
    it "runs ffmpeg and returns the output path" do
      expected = remover.build_args("in.wav", "out.wav", 0.75)
      allow(ffmpeg).to receive(:run)

      expect(remover.render("in.wav", "out.wav", 0.75)).to eq("out.wav")
      expect(ffmpeg).to have_received(:run).with(expected)
    end
  end
end
