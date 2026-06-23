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

    # Builds a smooth gain envelope (a value in [0,1]) that ramps linearly from 0
    # to 1 over +fade_s+ at the start of each owned block and back to 0 at the
    # end, holding at 1 in between. Used as the mixer's volume value so a speaker
    # eases in and out instead of switching on with an audible click.
    #
    # With +fade_s+ of zero (or less) there is nothing to ramp, so it falls back
    # to the binary +owned+ expression, i.e. the old hard gate.
    #
    # @param intervals [Array<Interval>] owned intervals for a single track
    # @param buffer_s [Float] padding, in seconds, added to each side of a block
    # @param fade_s [Float] gain-ramp duration, in seconds, at each block edge
    # @return [String] e.g. "min(1,clip(min((t-0.900)/0.010,(2.100-t)/0.010),0,1))"
    #
    # ffmpeg's expression +min+ takes exactly two arguments, so the two ramp
    # legs are min'd together and the unity cap is the upper bound of +clip+.
    def envelope(intervals, buffer_s, fade_s)
      return owned(intervals, buffer_s) if fade_s <= 0

      ramps = intervals.map do |interval|
        start_at = [interval.start_at - buffer_s, 0.0].max
        end_at = interval.end_at + buffer_s
        format("clip(min((t-%<start>.3f)/%<fade>.3f,(%<end>.3f-t)/%<fade>.3f),0,1)",
               start: start_at, end: end_at, fade: fade_s)
      end
      "min(1,#{ramps.join("+")})"
    end
  end
end
