# frozen_string_literal: true

require "open3"
require "stringio"

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

  describe "#silencedetect with a progress block" do
    it "streams progress on stdout while still returning the marker stderr" do
      wait = instance_double(Thread, value: ok)
      allow(Open3).to receive(:popen3)
        .and_yield(StringIO.new, StringIO.new("out_time=00:00:03.000000\nprogress=end\n"),
                   StringIO.new("silence_start: 1.0"), wait)

      seconds = []
      stderr = ffmpeg.silencedetect("a.wav") { |s| seconds << s }

      expect(stderr).to eq("silence_start: 1.0")
      expect(seconds).to eq([3.0])
      expect(Open3).to have_received(:popen3)
        .with("ffmpeg", "-progress", "pipe:1", "-hide_banner", "-nostats", "-i", "a.wav",
              "-af", "silencedetect=noise=-30dB:d=0.1", "-f", "null", "-")
    end

    it "raises with the captured stderr when the streamed scan fails" do
      wait = instance_double(Thread, value: fail_status)
      allow(Open3).to receive(:popen3)
        .and_yield(StringIO.new, StringIO.new(""), StringIO.new("nope"), wait)
      expect { ffmpeg.silencedetect("a.wav") { |s| s } }
        .to raise_error(CrosstalkCleaner::FfmpegError, /silencedetect failed.*nope/)
    end
  end

  describe "#ebur128 with a progress block" do
    it "streams progress on stdout while still returning the summary stderr" do
      wait = instance_double(Thread, value: ok)
      allow(Open3).to receive(:popen3)
        .and_yield(StringIO.new, StringIO.new("out_time=00:00:02.000000\nprogress=end\n"),
                   StringIO.new("I: -18.0 LUFS"), wait)

      seconds = []
      stderr = ffmpeg.ebur128("a.wav", "between(t,0,5)") { |s| seconds << s }

      expect(stderr).to eq("I: -18.0 LUFS")
      expect(seconds).to eq([2.0])
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

  describe "#run with a progress block" do
    def streaming(stdout_text, status, stderr_text = "")
      wait = instance_double(Thread, value: status)
      allow(Open3).to receive(:popen3)
        .and_yield(StringIO.new, StringIO.new(stdout_text), StringIO.new(stderr_text), wait)
    end

    it "asks ffmpeg for machine-readable progress on stdout" do
      streaming("progress=end\n", ok)
      ffmpeg.run(["-i", "a.wav", "out.wav"]) { |secs| secs }
      expect(Open3).to have_received(:popen3)
        .with("ffmpeg", "-hide_banner", "-y", "-nostats", "-progress", "pipe:1", "-i", "a.wav", "out.wav")
    end

    it "yields the rendered output time in seconds for each report" do
      streaming("out_time=00:00:01.500000\nprogress=continue\nout_time=00:01:00.000000\nprogress=end\n", ok)
      seconds = []
      ffmpeg.run(["x"]) { |s| seconds << s }
      expect(seconds).to eq([1.5, 60.0])
    end

    it "ignores progress lines whose time is not yet known" do
      streaming("out_time=N/A\nout_time=00:00:02.000000\nprogress=end\n", ok)
      seconds = []
      ffmpeg.run(["x"]) { |s| seconds << s }
      expect(seconds).to eq([2.0])
    end

    it "raises when the streamed render fails" do
      streaming("", fail_status, "boom")
      expect { ffmpeg.run(["x"]) { |secs| secs } }.to raise_error(CrosstalkCleaner::FfmpegError, /ffmpeg failed: boom/)
    end
  end
end
