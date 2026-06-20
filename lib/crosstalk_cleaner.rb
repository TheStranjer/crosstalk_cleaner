# frozen_string_literal: true

module CrosstalkCleaner
  # Base class for all errors raised by the tool.
  class Error < StandardError; end

  # Raised for bad CLI arguments or environment configuration.
  class ConfigurationError < Error; end

  # Raised when an ffmpeg / ffprobe shell-out fails.
  class FfmpegError < Error; end
end

require_relative "crosstalk_cleaner/interval"
require_relative "crosstalk_cleaner/config"
require_relative "crosstalk_cleaner/ffmpeg"
require_relative "crosstalk_cleaner/silence_detector"
require_relative "crosstalk_cleaner/overlap_resolver"
require_relative "crosstalk_cleaner/audio_mixer"
require_relative "crosstalk_cleaner/silence_remover"
require_relative "crosstalk_cleaner/cleaner"
