# frozen_string_literal: true

require_relative "interval_expression"

module CrosstalkCleaner
  # Levels every track to a common loudness. For each track it measures the EBU
  # R128 integrated loudness over only the audio that is actually kept (its owned
  # intervals, so the long silent blocks never drag the measurement down) and
  # returns the per-track gain, in dB, needed to reach the target.
  #
  # The target is either a fixed LUFS value or +:auto+, in which case it is the
  # median of the tracks' own measured levels so the common level is drawn from
  # the actual speakers and adjustments stay small and centered.
  class VolumeNormalizer
    # Matches the integrated-loudness line ("I: -18.0 LUFS"). ebur128 prints it
    # both per-frame and once more in its final summary, so callers take the last.
    INTEGRATED = /\bI:\s*(-?\d+(?:\.\d+)?|-?inf|nan)\s+LUFS/i

    # Asymmetric clamp: a quiet track can be lifted a lot, but no track is ever
    # turned down far enough to crush a legitimate speaker toward silence.
    MAX_BOOST_DB = 15.0
    MAX_CUT_DB = 6.0

    # Below this much kept audio EBU R128 integrated loudness is unreliable, so
    # the track is left at its original level rather than risk a bad gain.
    MIN_OWNED_DURATION_S = 3.0

    # @param ffmpeg [Ffmpeg] the ffmpeg shell-out wrapper
    # @param target [Float, :auto] desired integrated loudness for every track in
    #   LUFS, or :auto to use the median of the measured per-track levels.
    # @param buffer_s [Float] block-buffer padding (matches the mixer) so the
    #   measured audio is exactly the audio that ends up in the mix.
    def initialize(ffmpeg, target:, buffer_s: 0.0)
      @ffmpeg = ffmpeg
      @target = target
      @buffer_s = buffer_s
    end

    # @param inputs [Array<String>] input file paths, in priority order
    # @param ownership_by_track [Hash{Integer=>Array<Interval>}] owned intervals
    # @return [Hash{Integer=>Float}] gain in dB per track with measurable audio;
    #   tracks that own too little audio or measure as silent are omitted and
    #   left at their original level.
    #
    # An optional block wraps each track that is actually measured: it is called
    # with the track index and a block that, given a progress sink, runs the
    # measurement (so a caller can drape a progress bar around the ebur128 pass).
    def gains(inputs, ownership_by_track, &)
      measured = measure_all(inputs, ownership_by_track, &)
      return {} if measured.empty?

      target = resolve_target(measured.values)
      measured.transform_values do |loudness|
        (target - loudness).clamp(-MAX_CUT_DB, MAX_BOOST_DB)
      end
    end

    # Integrated loudness (LUFS) of +path+ over its owned intervals, or nil when
    # the selection is effectively silent (ebur128 reports -inf/nan). An optional
    # block is forwarded to Ffmpeg#ebur128 to report measurement progress.
    def measure(path, intervals, &)
      expression = IntervalExpression.owned(intervals, @buffer_s)
      parse_loudness(@ffmpeg.ebur128(path, expression, &))
    end

    private

    # Measures every track that owns enough audio to trust, keyed by track index.
    def measure_all(inputs, ownership_by_track, &measure_block)
      measured = {}
      inputs.each_index do |index|
        intervals = ownership_by_track.fetch(index, [])
        next if owned_duration(intervals) < MIN_OWNED_DURATION_S

        loudness = measure_track(inputs[index], intervals, index, &measure_block)
        measured[index] = loudness unless loudness.nil?
      end
      measured
    end

    # Measures one track, letting an optional caller block wrap the pass (e.g. to
    # show a progress bar) while the actual measurement stays here.
    def measure_track(path, intervals, index, &measure_block)
      return measure(path, intervals) unless measure_block

      measure_block.call(index) { |on_progress| measure(path, intervals, &on_progress) }
    end

    # The common level to aim for: a fixed target when one was given, otherwise
    # the median of the measured levels (a "normal" drawn from the speakers).
    def resolve_target(levels)
      return @target if @target.is_a?(Numeric)

      median(levels)
    end

    def median(values)
      sorted = values.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    def owned_duration(intervals)
      intervals.sum(&:duration)
    end

    def parse_loudness(text)
      match = text.scan(INTEGRATED).last
      return nil unless match

      value = Float(match.first, exception: false)
      return nil if value.nil? || !value.finite?

      value
    end
  end
end
