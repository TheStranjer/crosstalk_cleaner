# frozen_string_literal: true

require "open3"

RSpec.describe CrosstalkCleaner::Ffmpeg do
  subject(:ffmpeg) { described_class.new(ffmpeg_bin: "ffmpeg", ffprobe_bin: "ffprobe") }

  let(:ok) { instance_double(Process::Status, success?: true) }
  let(:fail_status) { instance_double(Process::Status, success?: false) }

  describe "#duration" do
    it "parses ffprobe output into a float" do
      allow(Open3).to receive(:capture3).and_return(["12.34\n", "", ok])
      expect(ffmpeg.duration("a.wav")).to eq(12.34)
    end

    it "raises when ffprobe fails" do
      allow(Open3).to receive(:capture3).and_return(["", "boom", fail_status])
      expect { ffmpeg.duration("a.wav") }.to raise_error(CrosstalkCleaner::FfmpegError, /ffprobe failed/)
    end

    it "raises when the duration cannot be parsed" do
      allow(Open3).to receive(:capture3).and_return(["N/A\n", "", ok])
      expect { ffmpeg.duration("a.wav") }.to raise_error(CrosstalkCleaner::FfmpegError, /could not parse/)
    end
  end

  describe "#silencedetect" do
    it "returns ffmpeg stderr on success" do
      allow(Open3).to receive(:capture3).and_return(["", "silence_start: 1.0", ok])
      expect(ffmpeg.silencedetect("a.wav")).to eq("silence_start: 1.0")
    end

    it "passes the configured filter to ffmpeg" do
      allow(Open3).to receive(:capture3).and_return(["", "", ok])
      ffmpeg.silencedetect("a.wav", noise: "-40dB", min_duration: 0.2)
      expect(Open3).to have_received(:capture3)
        .with("ffmpeg", "-hide_banner", "-nostats", "-i", "a.wav",
              "-af", "silencedetect=noise=-40dB:d=0.2", "-f", "null", "-")
    end

    it "defaults the filter to the noise and min duration given at construction" do
      configured = described_class.new(silencedetect_noise: "-55dB", silencedetect_min_duration: 0.5)
      allow(Open3).to receive(:capture3).and_return(["", "", ok])
      configured.silencedetect("a.wav")
      expect(Open3).to have_received(:capture3)
        .with("ffmpeg", "-hide_banner", "-nostats", "-i", "a.wav",
              "-af", "silencedetect=noise=-55dB:d=0.5", "-f", "null", "-")
    end

    it "raises when ffmpeg fails" do
      allow(Open3).to receive(:capture3).and_return(["", "nope", fail_status])
      expect { ffmpeg.silencedetect("a.wav") }.to raise_error(CrosstalkCleaner::FfmpegError, /silencedetect failed/)
    end
  end

  describe "#ebur128" do
    it "selects the given expression then measures, returning stderr" do
      allow(Open3).to receive(:capture3).and_return(["", "I: -18.0 LUFS", ok])
      expect(ffmpeg.ebur128("a.wav", "between(t,0.000,5.000)")).to eq("I: -18.0 LUFS")
      expect(Open3).to have_received(:capture3)
        .with("ffmpeg", "-hide_banner", "-nostats", "-i", "a.wav",
              "-af", "aselect='between(t,0.000,5.000)',ebur128", "-f", "null", "-")
    end

    it "raises when ffmpeg fails" do
      allow(Open3).to receive(:capture3).and_return(["", "nope", fail_status])
      expect { ffmpeg.ebur128("a.wav", "between(t,0,5)") }
        .to raise_error(CrosstalkCleaner::FfmpegError, /ebur128 failed/)
    end
  end

  describe "#run" do
    it "prepends the binary and standard flags" do
      allow(Open3).to receive(:capture3).and_return(["", "", ok])
      ffmpeg.run(["-i", "a.wav", "out.wav"])
      expect(Open3).to have_received(:capture3)
        .with("ffmpeg", "-hide_banner", "-y", "-i", "a.wav", "out.wav")
    end

    it "returns true on success" do
      allow(Open3).to receive(:capture3).and_return(["", "", ok])
      expect(ffmpeg.run(["x"])).to be(true)
    end

    it "raises on failure" do
      allow(Open3).to receive(:capture3).and_return(["", "bad", fail_status])
      expect { ffmpeg.run(["x"]) }.to raise_error(CrosstalkCleaner::FfmpegError, /ffmpeg failed/)
    end
  end
end
