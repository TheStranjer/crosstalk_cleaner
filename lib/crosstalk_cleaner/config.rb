# frozen_string_literal: true

require "pathname"

module CrosstalkCleaner
  # Resolves runtime configuration from the command-line arguments and the
  # supported environment variables (OUTPUT, SILENCE_LIMIT, SILENCE_BUFFER,
  # CROSSTALK_TOLERANCE,
  # BLOCK_BUFFER, FADE, SILENCEDETECT_NOISE, SILENCEDETECT_MIN_DURATION,
  # NOISE_FLOOR, DECLICK, RESAMPLE_RATE, CHANNEL_LAYOUT, VOLUME_NORMALIZE,
  # NORMALIZE_TARGET).
  class Config
    DEFAULT_SILENCE_LIMIT_MS = 750
    DEFAULT_CROSSTALK_TOLERANCE_MS = 300
    DEFAULT_BLOCK_BUFFER_MS = 100
    DEFAULT_FADE_MS = 10
    DEFAULT_SILENCEDETECT_NOISE = "-30dB"
    DEFAULT_SILENCEDETECT_MIN_DURATION = 0.1
    DEFAULT_NOISE_FLOOR = "-30dB"
    DEFAULT_DECLICK = true
    DEFAULT_RESAMPLE_RATE = 48_000
    DEFAULT_CHANNEL_LAYOUT = "stereo"
    DEFAULT_FFMPEG_BIN = "ffmpeg"
    DEFAULT_FFPROBE_BIN = "ffprobe"
    DEFAULT_VOLUME_NORMALIZE = true
    DEFAULT_NORMALIZE_TARGET = :auto
    FALSEY = %w[0 false no off].freeze

    attr_reader :inputs, :output, :silence_limit_ms, :silence_buffer_ms, :crosstalk_tolerance_ms, :block_buffer_ms,
                :fade_ms,
                :silencedetect_noise, :silencedetect_min_duration, :noise_floor, :declick, :resample_rate,
                :channel_layout, :ffmpeg_bin, :ffprobe_bin, :volume_normalize, :normalize_target

    # @param argv [Array<String>] input wav files in priority order (first = top)
    # @param env [Hash] environment variables (defaults to ENV)
    def initialize(argv, env: ENV)
      @inputs = Array(argv).dup
      validate_inputs!
      resolve_settings(env)
      @output = resolve_output(env["OUTPUT"])
    end

    # Crosstalk tolerance expressed in seconds for ffmpeg/comparison use.
    def crosstalk_tolerance_s = crosstalk_tolerance_ms / 1000.0

    # Silence limit expressed in seconds.
    def silence_limit_s = silence_limit_ms / 1000.0

    # Silence buffer (silence kept at the leading edge of each trimmed gap)
    # expressed in seconds.
    def silence_buffer_s = silence_buffer_ms / 1000.0

    # Block buffer (padding around each owned block) expressed in seconds.
    def block_buffer_s = block_buffer_ms / 1000.0

    # Fade (gain ramp at each owned block edge) expressed in seconds.
    def fade_s = fade_ms / 1000.0

    private

    def resolve_settings(env)
      @silence_limit_ms = positive_int(env["SILENCE_LIMIT"], DEFAULT_SILENCE_LIMIT_MS, "SILENCE_LIMIT")
      @silence_buffer_ms = positive_int(env["SILENCE_BUFFER"], @silence_limit_ms, "SILENCE_BUFFER")
      @crosstalk_tolerance_ms = positive_int(env["CROSSTALK_TOLERANCE"], DEFAULT_CROSSTALK_TOLERANCE_MS,
                                             "CROSSTALK_TOLERANCE")
      @block_buffer_ms = positive_int(env["BLOCK_BUFFER"], DEFAULT_BLOCK_BUFFER_MS, "BLOCK_BUFFER")
      @fade_ms = positive_int(env["FADE"], DEFAULT_FADE_MS, "FADE", allow_zero: true)
      @resample_rate = positive_int(env["RESAMPLE_RATE"], DEFAULT_RESAMPLE_RATE, "RESAMPLE_RATE")
      @channel_layout = string_value(env["CHANNEL_LAYOUT"], DEFAULT_CHANNEL_LAYOUT)
      @ffmpeg_bin = string_value(env["FFMPEG_BIN"], DEFAULT_FFMPEG_BIN)
      @ffprobe_bin = string_value(env["FFPROBE_BIN"], DEFAULT_FFPROBE_BIN)
      resolve_detection(env)
      resolve_normalization(env)
    end

    def resolve_detection(env)
      @silencedetect_noise = string_value(env["SILENCEDETECT_NOISE"], DEFAULT_SILENCEDETECT_NOISE)
      @silencedetect_min_duration = positive_float(env["SILENCEDETECT_MIN_DURATION"],
                                                   DEFAULT_SILENCEDETECT_MIN_DURATION, "SILENCEDETECT_MIN_DURATION")
      @noise_floor = string_value(env["NOISE_FLOOR"], DEFAULT_NOISE_FLOOR)
      @declick = boolean_value(env["DECLICK"], DEFAULT_DECLICK)
    end

    def resolve_normalization(env)
      @volume_normalize = boolean_value(env["VOLUME_NORMALIZE"], DEFAULT_VOLUME_NORMALIZE)
      @normalize_target = target_value(env["NORMALIZE_TARGET"], DEFAULT_NORMALIZE_TARGET, "NORMALIZE_TARGET")
    end

    def validate_inputs!
      raise ConfigurationError, "no input files given" if @inputs.empty?

      @inputs.each do |path|
        raise ConfigurationError, "input file not found: #{path}" unless File.file?(path)
      end
    end

    def resolve_output(value)
      return value if value && !value.empty?

      Pathname.new(@inputs.first).expand_path.dirname.join("output.wav").to_s
    end

    # Integer setting. With +allow_zero+ the value may be zero (for settings where
    # 0 means "off"); otherwise it must be strictly positive.
    def positive_int(value, default, name, allow_zero: false)
      return default if value.nil? || value.empty?

      parsed = Integer(value, exception: false)
      return parsed if parsed && (allow_zero ? !parsed.negative? : parsed.positive?)

      qualifier = allow_zero ? "non-negative" : "positive"
      raise ConfigurationError, "#{name} must be a #{qualifier} integer (got #{value.inspect})"
    end

    def positive_float(value, default, name)
      return default if value.nil? || value.empty?

      parsed = Float(value, exception: false)
      return parsed if parsed&.positive?

      raise ConfigurationError, "#{name} must be a positive number (got #{value.inspect})"
    end

    # Free-form string setting: an empty or missing value falls back to the default.
    def string_value(value, default)
      return default if value.nil? || value.empty?

      value
    end

    # Loudness target: empty/missing or "auto" selects the data-driven median
    # (:auto); otherwise any finite number is a fixed absolute LUFS target.
    def target_value(value, default, name)
      return default if value.nil? || value.empty? || value.strip.casecmp?("auto")

      parsed = Float(value, exception: false)
      return parsed if parsed&.finite?

      raise ConfigurationError, "#{name} must be a number or 'auto' (got #{value.inspect})"
    end

    # Boolean setting: empty/missing uses the default, "0"/"false"/"no"/"off"
    # (case-insensitive) disable it, anything else enables it.
    def boolean_value(value, default)
      return default if value.nil? || value.empty?

      !FALSEY.include?(value.strip.downcase)
    end
  end
end
