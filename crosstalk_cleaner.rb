#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "lib/crosstalk_cleaner"

# Command-line front end. Usage:
#   ruby ./crosstalk_cleaner.rb top_user.wav second_user.wav third.wav
module CrosstalkCleaner
  # Wires the CLI arguments and environment into the pipeline.
  class CLI
    def self.run(argv, env: ENV, logger: $stdout, error_logger: $stderr)
      config = Config.new(argv, env: env)
      Cleaner.new(config, logger: logger).run
      0
    rescue Error => e
      error_logger.puts("crosstalk_cleaner: #{e.message}")
      1
    end
  end
end

exit(CrosstalkCleaner::CLI.run(ARGV)) if $PROGRAM_NAME == __FILE__
