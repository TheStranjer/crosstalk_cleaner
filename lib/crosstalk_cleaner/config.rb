# frozen_string_literal: true

require "pathname"

module CrosstalkCleaner
  # Resolves runtime configuration from the command-line arguments and the
  # supported environment variables (OUTPUT, SILENCE_LIMIT, CROSSTALK_TOLERANCE).
  class Config
    DEFAULT_SILENCE_LIMIT_MS = 750
    DEFAULT_CROSSTALK_TOLERANCE_MS = 300

    attr_reader :inputs, :output, :silence_limit_ms, :crosstalk_tolerance_ms

    # @param argv [Array<String>] input wav files in priority order (first = top)
    # @param env [Hash] environment variables (defaults to ENV)
    def initialize(argv, env: ENV)
      @inputs = Array(argv).dup
      validate_inputs!

      @silence_limit_ms = positive_int(env["SILENCE_LIMIT"], DEFAULT_SILENCE_LIMIT_MS, "SILENCE_LIMIT")
      @crosstalk_tolerance_ms = positive_int(env["CROSSTALK_TOLERANCE"], DEFAULT_CROSSTALK_TOLERANCE_MS,
                                             "CROSSTALK_TOLERANCE")
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

    private

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
  end
end
