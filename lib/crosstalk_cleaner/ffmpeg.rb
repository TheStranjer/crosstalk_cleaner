# frozen_string_literal: true

require "open3"

module CrosstalkCleaner
  # Thin wrapper around the ffmpeg / ffprobe binaries. Every shell-out lives here
  # so the rest of the pipeline stays pure and testable; tests stub these methods.
  class Ffmpeg
    SILENCEDETECT_NOISE = "-30dB"
    SILENCEDETECT_MIN_DURATION = 0.1

    def initialize(ffmpeg_bin: "ffmpeg", ffprobe_bin: "ffprobe",
                   silencedetect_noise: SILENCEDETECT_NOISE,
                   silencedetect_min_duration: SILENCEDETECT_MIN_DURATION)
      @ffmpeg_bin = ffmpeg_bin
      @ffprobe_bin = ffprobe_bin
      @silencedetect_noise = silencedetect_noise
      @silencedetect_min_duration = silencedetect_min_duration
    end

    # Returns the duration of +path+ in seconds.
    def duration(path)
      args = [@ffprobe_bin, "-v", "error", "-show_entries", "format=duration",
              "-of", "default=noprint_wrappers=1:nokey=1", path]
      stdout, stderr, status = Open3.capture3(*args)
      raise FfmpegError, "ffprobe failed for #{path}: #{stderr}" unless status.success?

      Float(stdout.strip)
    rescue ArgumentError
      raise FfmpegError, "could not parse duration for #{path}: #{stdout.inspect}"
    end

    # Runs silencedetect over +path+ and returns ffmpeg's stderr text for parsing.
    def silencedetect(path, noise: @silencedetect_noise, min_duration: @silencedetect_min_duration)
      filter = "silencedetect=noise=#{noise}:d=#{min_duration}"
      args = [@ffmpeg_bin, "-hide_banner", "-nostats", "-i", path, "-af", filter, "-f", "null", "-"]
      _stdout, stderr, status = Open3.capture3(*args)
      raise FfmpegError, "silencedetect failed for #{path}: #{stderr}" unless status.success?

      stderr
    end

    # Measures EBU R128 loudness over only the audio selected by +select_expr+
    # (an aselect expression covering a track's owned intervals) and returns
    # ffmpeg's stderr text, which carries the integrated-loudness summary.
    def ebur128(path, select_expr)
      filter = "aselect='#{select_expr}',ebur128"
      args = [@ffmpeg_bin, "-hide_banner", "-nostats", "-i", path, "-af", filter, "-f", "null", "-"]
      _stdout, stderr, status = Open3.capture3(*args)
      raise FfmpegError, "ebur128 failed for #{path}: #{stderr}" unless status.success?

      stderr
    end

    # Executes an ffmpeg argument vector (without the leading binary name). When
    # a block is given the render is streamed and the block is called with the
    # output time produced so far, in seconds, each time ffmpeg reports progress.
    def run(args, &)
      block_given? ? run_streamed(args, &) : run_captured(args)
      true
    end

    private

    def run_captured(args)
      full = [@ffmpeg_bin, "-hide_banner", "-y", *args]
      _stdout, stderr, status = Open3.capture3(*full)
      raise FfmpegError, "ffmpeg failed: #{stderr}" unless status.success?
    end

    # Adds -progress so ffmpeg emits machine-readable key=value lines on stdout,
    # parses the out_time field from them and reports it as seconds. stderr is
    # drained on a thread so a chatty render can never deadlock on a full pipe.
    def run_streamed(args, &on_progress)
      full = [@ffmpeg_bin, "-hide_banner", "-y", "-nostats", "-progress", "pipe:1", *args]
      Open3.popen3(*full) do |stdin, stdout, stderr, wait_thread|
        stdin.close
        drain = Thread.new { stderr.read }
        stdout.each_line { |line| report_progress(line, on_progress) }
        status = wait_thread.value
        raise FfmpegError, "ffmpeg failed: #{drain.value}" unless status.success?
      end
    end

    # Reports the seconds parsed from an "out_time=HH:MM:SS.micros" progress line.
    def report_progress(line, on_progress)
      key, _, value = line.partition("=")
      return unless key.strip == "out_time"

      seconds = parse_timecode(value.strip)
      on_progress.call(seconds) if seconds
    end

    def parse_timecode(value)
      return nil unless value =~ /\A(\d+):(\d{2}):(\d{2}(?:\.\d+)?)\z/

      (Regexp.last_match(1).to_i * 3600) + (Regexp.last_match(2).to_i * 60) + Regexp.last_match(3).to_f
    end
  end
end
