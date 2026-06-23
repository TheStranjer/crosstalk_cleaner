# frozen_string_literal: true

module CrosstalkCleaner
  # Builds the ffmpeg time expression that is true while +t+ falls inside one of a
  # track's owned intervals (each padded by the block buffer). Shared by the mixer
  # (to decide when a track is unmuted) and the volume normalizer (to select only
  # the kept audio for loudness measurement).
  module IntervalExpression
    module_function

    # @param intervals [Array<Interval>] owned intervals for a single track
    # @param buffer_s [Float] padding, in seconds, added to each side of a block
    # @return [String] e.g. "between(t,0.900,2.100)+between(t,4.000,5.500)"
    def owned(intervals, buffer_s)
      intervals.map do |interval|
        start_at = [interval.start_at - buffer_s, 0.0].max
        end_at = interval.end_at + buffer_s
        format("between(t,%<start>.3f,%<end>.3f)", start: start_at, end: end_at)
      end.join("+")
    end
  end
end
