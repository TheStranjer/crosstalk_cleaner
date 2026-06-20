# frozen_string_literal: true

RSpec.describe CrosstalkCleaner::SilenceDetector do
  subject(:detector) { described_class.new(ffmpeg) }

  let(:ffmpeg) { instance_double(CrosstalkCleaner::Ffmpeg) }

  describe "#parse_silences" do
    it "pairs silence_start and silence_end lines" do
      text = <<~LOG
        [silencedetect @ 0x1] silence_start: 2.0
        [silencedetect @ 0x1] silence_end: 4.0 | silence_duration: 2.0
        [silencedetect @ 0x1] silence_start: 7.0
        [silencedetect @ 0x1] silence_end: 9.0 | silence_duration: 2.0
      LOG
      expect(detector.parse_silences(text, 10.0)).to eq([[2.0, 4.0], [7.0, 9.0]])
    end

    it "closes a trailing silence_start at the track duration" do
      expect(detector.parse_silences("silence_start: 8.0", 10.0)).to eq([[8.0, 10.0]])
    end

    it "clamps out-of-range values to the duration" do
      text = "silence_start: -1.0\nsilence_end: 99.0"
      expect(detector.parse_silences(text, 10.0)).to eq([[0.0, 10.0]])
    end

    it "drops degenerate pairs where end <= start" do
      text = "silence_start: 5.0\nsilence_end: 5.0"
      expect(detector.parse_silences(text, 10.0)).to eq([])
    end

    it "returns nothing when there is no silence" do
      expect(detector.parse_silences("nothing here", 10.0)).to eq([])
    end
  end

  describe "#invert" do
    it "produces speech between silences" do
      speech = detector.invert([[2.0, 4.0], [7.0, 9.0]], 10.0, 1)
      expect(speech).to eq([
                             interval(0.0, 2.0, 1),
                             interval(4.0, 7.0, 1),
                             interval(9.0, 10.0, 1)
                           ])
    end

    it "treats a fully silent track as having no speech" do
      expect(detector.invert([[0.0, 10.0]], 10.0, 0)).to eq([])
    end

    it "treats a fully voiced track as one speech interval" do
      expect(detector.invert([], 10.0, 0)).to eq([interval(0.0, 10.0, 0)])
    end
  end

  describe "#speech_intervals" do
    it "probes duration, runs silencedetect, and inverts the result" do
      allow(ffmpeg).to receive(:duration).with("a.wav").and_return(10.0)
      allow(ffmpeg).to receive(:silencedetect).with("a.wav")
                                              .and_return("silence_start: 2.0\nsilence_end: 4.0")

      expect(detector.speech_intervals("a.wav", 2))
        .to eq([interval(0.0, 2.0, 2), interval(4.0, 10.0, 2)])
    end
  end
end
