# frozen_string_literal: true

require "pathname"

module CrosstalkCleaner
  # Resolves runtime configuration from the command-line arguments and the
  # supported environment variables (OUTPUT, SILENCE_LIMIT, CROSSTALK_TOLERANCE,
  # BLOCK_BUFFER, SILENCEDETECT_NOISE, SILENCEDETECT_MIN_DURATION, NOISE_FLOOR,
  # RESAMPLE_RATE, CHANNEL_LAYOUT).
  class Config
    DEFAULT_SILENCE_LIMIT_MS = 750
    DEFAULT_CROSSTALK_TOLERANCE_MS = 300
    DEFAULT_BLOCK_BUFFER_MS = 100
    DEFAULT_SILENCEDETECT_NOISE = "-30dB"
    DEFAULT_SILENCEDETECT_MIN_DURATION = 0.1
    DEFAULT_NOISE_FLOOR = "-30dB"
    DEFAULT_RESAMPLE_RATE = 48_000
    DEFAULT_CHANNEL_LAYOUT = "stereo"
    DEFAULT_FFMPEG_BIN = "ffmpeg"
    DEFAULT_FFPROBE_BIN = "ffprobe"

    attr_reader :inputs, :output, :silence_limit_ms, :crosstalk_tolerance_ms, :block_buffer_ms,
                :silencedetect_noise, :silencedetect_min_duration, :noise_floor, :resample_rate,
                :channel_layout, :ffmpeg_bin, :ffprobe_bin

    # @param argv [Array<String>] input wav files in priority order (first = top)
    # @param env [Hash] environment variables (defaults to ENV)
    def initialize(argv, env: ENV)
      @inputs = Array(argv).dup
      validate_inputs!
      resolve_settings(env)
      @output = resolve_output(env["OUTPUT"])
    end

    # Crosstalk tolerance expressed in seconds for ffmpeg/comparison use.
    def crosstalk_tolerance_s
      crosstalk_tolerance_ms / 1000.0
    end

    # Silence limit expressed in seconds.
    def silence_limit_s
      silence_limit_ms / 1000.0
    end

    # Block buffer (padding around each owned block) expressed in seconds.
    def block_buffer_s
      block_buffer_ms / 1000.0
    end

    private

    def resolve_settings(env)
      @silence_limit_ms = positive_int(env["SILENCE_LIMIT"], DEFAULT_SILENCE_LIMIT_MS, "SILENCE_LIMIT")
      @crosstalk_tolerance_ms = positive_int(env["CROSSTALK_TOLERANCE"], DEFAULT_CROSSTALK_TOLERANCE_MS,
                                             "CROSSTALK_TOLERANCE")
      @block_buffer_ms = positive_int(env["BLOCK_BUFFER"], DEFAULT_BLOCK_BUFFER_MS, "BLOCK_BUFFER")
      @silencedetect_noise = string_value(env["SILENCEDETECT_NOISE"], DEFAULT_SILENCEDETECT_NOISE)
      @silencedetect_min_duration = positive_float(env["SILENCEDETECT_MIN_DURATION"],
                                                   DEFAULT_SILENCEDETECT_MIN_DURATION, "SILENCEDETECT_MIN_DURATION")
      @noise_floor = string_value(env["NOISE_FLOOR"], DEFAULT_NOISE_FLOOR)
      @resample_rate = positive_int(env["RESAMPLE_RATE"], DEFAULT_RESAMPLE_RATE, "RESAMPLE_RATE")
      @channel_layout = string_value(env["CHANNEL_LAYOUT"], DEFAULT_CHANNEL_LAYOUT)
      @ffmpeg_bin = string_value(env["FFMPEG_BIN"], DEFAULT_FFMPEG_BIN)
      @ffprobe_bin = string_value(env["FFPROBE_BIN"], DEFAULT_FFPROBE_BIN)
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

    def positive_int(value, default, name)
      return default if value.nil? || value.empty?

      parsed = Integer(value, exception: false)
      return parsed if parsed&.positive?

      raise ConfigurationError, "#{name} must be a positive integer (got #{value.inspect})"
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
  end
end
