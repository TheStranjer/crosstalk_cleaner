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

    # Executes an ffmpeg argument vector (without the leading binary name).
    def run(args)
      full = [@ffmpeg_bin, "-hide_banner", "-y", *args]
      _stdout, stderr, status = Open3.capture3(*full)
      raise FfmpegError, "ffmpeg failed: #{stderr}" unless status.success?

      true
    end
  end
end
