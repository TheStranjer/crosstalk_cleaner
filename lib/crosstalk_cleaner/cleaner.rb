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
      @remover = SilenceRemover.new(@ffmpeg, noise_floor: config.noise_floor, declick: config.declick)
    end

    # Runs the pipeline and returns the path to the final output file.
    def run
      ownership = resolve_ownership
      gains = compute_gains(ownership)
      Dir.mktmpdir("crosstalk_cleaner") do |dir|
        intermediate = File.join(dir, "crosstalk_cleaned.wav")
        collapse(ownership, gains, intermediate)
        remove_silence(intermediate)
      end
      log "Wrote #{@config.output}"
      @config.output
    end

    # Detects speech on every track and resolves crosstalk into per-track
    # ownership intervals.
    def resolve_ownership
      track_intervals = @config.inputs.each_with_index.map do |path, index|
        detect_speech(path, index)
      end
      @resolver.resolve(track_intervals).group_by(&:track_index)
    end

    private

    # Detects speech on one track while a progress bar tracks how far through the
    # track ffmpeg's silence scan has read.
    def detect_speech(path, index)
      with_bar("Detecting speech on #{path}", duration_ms(path)) do |bar|
        @detector.speech_intervals(path, index) { |seconds| bar.update(ms(seconds)) }
      end
    end

    # Trims dead silence while a progress bar tracks output time written. The cut
    # output is shorter than the input, so the bar fills partway before #finish
    # snaps it to 100%.
    def remove_silence(intermediate)
      label = "Removing dead silence (keeping at most #{@config.silence_limit_ms}ms)"
      with_bar(label, duration_ms(intermediate)) do |bar|
        @remover.render(intermediate, @config.output, @config.silence_limit_s) do |seconds|
          bar.update(ms(seconds))
        end
      end
    end

    # Renders the crosstalk-free mix while a progress bar tracks how many output
    # samples ffmpeg has produced against the total the mix will contain.
    def collapse(ownership, gains, intermediate)
      label = "Collapsing #{@config.inputs.size} tracks into a single crosstalk-free file"
      rate = @config.resample_rate
      with_bar(label, total_samples(rate), unit: "samples") do |bar|
        @mixer.render(@config.inputs, ownership, intermediate, gains: gains) do |seconds|
          bar.update((seconds * rate).round)
        end
      end
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
      gains = @normalizer.gains(@config.inputs, ownership) do |index, &measure|
        measure_volume(@config.inputs[index], index, &measure)
      end
      gains.each { |index, gain| log format("  track %<idx>d gain %<gain>+.2f dB", idx: index, gain: gain) }
      gains
    end

    # Measures one track's loudness while a progress bar tracks the ebur128 pass.
    # The bar stalls over skipped silence and jumps over kept speech, since only
    # the owned audio is selected, but still reaches 100% at the track's end.
    def measure_volume(path, index, &)
      with_bar(format("  measuring track %<idx>d", idx: index), duration_ms(path)) do |bar|
        yield(->(seconds) { bar.update(ms(seconds)) })
      end
    end

    def build_ffmpeg(config)
      Ffmpeg.new(ffmpeg_bin: config.ffmpeg_bin, ffprobe_bin: config.ffprobe_bin,
                 silencedetect_noise: config.silencedetect_noise,
                 silencedetect_min_duration: config.silencedetect_min_duration)
    end

    # Runs the block with a started progress bar, finishing it afterward (which
    # snaps it to 100% on a TTY), and returns whatever the block returns.
    def with_bar(label, total, unit: "ms")
      bar = ProgressBar.new(@logger, label, total, unit: unit)
      bar.start
      result = yield bar
      bar.finish
      result
    end

    def duration_ms(path)
      ms(@ffmpeg.duration(path))
    end

    def ms(seconds)
      (seconds * 1000).round
    end

    def log(message)
      @logger.puts(message)
    end
  end
end
