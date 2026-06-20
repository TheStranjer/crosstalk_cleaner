# frozen_string_literal: true

require_relative "../lib/crosstalk_cleaner"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed
end

# Convenience builder for Interval objects in specs.
def interval(start_at, end_at, track_index)
  CrosstalkCleaner::Interval.new(start_at: start_at, end_at: end_at, track_index: track_index)
end
