# frozen_string_literal: true

require "tmpdir"

require_relative "ffmpeg"
require_relative "silence_detector"
require_relative "overlap_resolver"
require_relative "audio_mixer"
require_relative "silence_remover"

module CrosstalkCleaner
  # Orchestrates the full pipeline: detect speech per track, resolve crosstalk
  # into a single file, then strip dead silence.
  class Cleaner
    def initialize(config, ffmpeg: nil, logger: $stdout)
      @config = config
      @ffmpeg = ffmpeg || build_ffmpeg(config)
      @logger = logger
      @detector = SilenceDetector.new(@ffmpeg)
      @resolver = OverlapResolver.new(tolerance_s: config.crosstalk_tolerance_s)
      @mixer = AudioMixer.new(@ffmpeg, buffer_s: config.block_buffer_s,
                                       resample_rate: config.resample_rate, channel_layout: config.channel_layout)
      @remover = SilenceRemover.new(@ffmpeg, noise_floor: config.noise_floor)
    end

    # Runs the pipeline and returns the path to the final output file.
    def run
      ownership = resolve_ownership
      Dir.mktmpdir("crosstalk_cleaner") do |dir|
        intermediate = File.join(dir, "crosstalk_cleaned.wav")
        log "Collapsing #{@config.inputs.size} tracks into a single crosstalk-free file"
        @mixer.render(@config.inputs, ownership, intermediate)
        log "Removing dead silence (keeping at most #{@config.silence_limit_ms}ms)"
        @remover.render(intermediate, @config.output, @config.silence_limit_s)
      end
      log "Wrote #{@config.output}"
      @config.output
    end

    # Detects speech on every track and resolves crosstalk into per-track
    # ownership intervals.
    def resolve_ownership
      track_intervals = @config.inputs.each_with_index.map do |path, index|
        log "Detecting speech on #{path}"
        @detector.speech_intervals(path, index)
      end
      @resolver.resolve(track_intervals).group_by(&:track_index)
    end

    private

    def build_ffmpeg(config)
      Ffmpeg.new(ffmpeg_bin: config.ffmpeg_bin, ffprobe_bin: config.ffprobe_bin,
                 silencedetect_noise: config.silencedetect_noise,
                 silencedetect_min_duration: config.silencedetect_min_duration)
    end

    def log(message)
      @logger.puts(message)
    end
  end
end
