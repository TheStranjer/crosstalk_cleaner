# frozen_string_literal: true

module CrosstalkCleaner
  # A half-open time interval [start_at, end_at) measured in seconds, owned by the
  # track at +track_index+. Used both for detected speech and for resolved
  # ownership ranges.
  class Interval
    attr_reader :start_at, :end_at, :track_index

    def initialize(start_at:, end_at:, track_index:)
      raise ArgumentError, "start_at must be <= end_at" if start_at > end_at

      @start_at = start_at.to_f
      @end_at = end_at.to_f
      @track_index = track_index
    end

    def duration
      end_at - start_at
    end

    def empty?
      duration <= 0
    end

    # Does this interval contain the instant +time+ (half-open)?
    def cover?(time)
      time >= start_at && time < end_at
    end

    def ==(other)
      other.is_a?(Interval) &&
        start_at == other.start_at &&
        end_at == other.end_at &&
        track_index == other.track_index
    end
    alias eql? ==

    def hash
      [start_at, end_at, track_index].hash
    end

    def to_s
      format("track=%<idx>d [%<start>.3f, %<end>.3f)", idx: track_index, start: start_at, end: end_at)
    end
  end
end
