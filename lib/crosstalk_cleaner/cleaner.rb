# frozen_string_literal: true

require "tmpdir"

require_relative "ffmpeg"
require_relative "silence_detector"
require_relative "overlap_resolver"
require_relative "volume_normalizer"
require_relative "audio_mixer"
require_relative "silence_remover"
require_relative "progress_bar"

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
      @normalizer = VolumeNormalizer.new(@ffmpeg, target: config.normalize_target, buffer_s: config.block_buffer_s)
      @mixer = AudioMixer.new(@ffmpeg, buffer_s: config.block_buffer_s, fade_s: config.fade_s,
                                       resample_rate: config.resample_rate, channel_layout: config.channel_layout)
      @remover = SilenceRemover.new(@ffmpeg, noise_floor: config.noise_floor)
    end

    # Runs the pipeline and returns the path to the final output file.
    def run
      ownership = resolve_ownership
      gains = compute_gains(ownership)
      Dir.mktmpdir("crosstalk_cleaner") do |dir|
        intermediate = File.join(dir, "crosstalk_cleaned.wav")
        collapse(ownership, gains, intermediate)
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

    # Renders the crosstalk-free mix while a progress bar tracks how many output
    # samples ffmpeg has produced against the total the mix will contain.
    def collapse(ownership, gains, intermediate)
      label = "Collapsing #{@config.inputs.size} tracks into a single crosstalk-free file"
      rate = @config.resample_rate
      bar = ProgressBar.new(@logger, label, total_samples(rate))
      bar.start
      @mixer.render(@config.inputs, ownership, intermediate, gains: gains) do |seconds|
        bar.update((seconds * rate).round)
      end
      bar.finish
    end

    # Total output samples the mix will hold: the longest input drives the length
    # (amix runs to the longest stream) at the mix sample rate.
    def total_samples(rate)
      (@config.inputs.map { |path| @ffmpeg.duration(path) }.max * rate).round
    end

    # Measures each track over its owned audio and returns per-track gains, unless
    # normalization is switched off (then the mixer runs exactly as before).
    def compute_gains(ownership)
      return {} unless @config.volume_normalize

      log "Normalizing track volumes"
      gains = @normalizer.gains(@config.inputs, ownership)
      gains.each { |index, gain| log format("  track %<idx>d gain %<gain>+.2f dB", idx: index, gain: gain) }
      gains
    end

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
