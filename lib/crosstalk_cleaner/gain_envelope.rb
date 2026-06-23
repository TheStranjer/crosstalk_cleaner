# frozen_string_literal: true

module CrosstalkCleaner
  # Generates a track's gain envelope and writes it as raw little-endian 32-bit
  # float mono samples. The envelope is 1.0 inside each owned block (padded by the
  # block buffer), 0.0 in the gaps, and eases between the two with a raised-cosine
  # ramp of +fade_s+ at every block edge.
  #
  # The mixer multiplies a track by this signal (via ffmpeg's +amultiply+) instead
  # of toggling a hard volume gate, so a speaker fades in and out at full sample
  # resolution rather than switching on with an audible click. Because the gating
  # lives in the sample data rather than a per-frame ffmpeg expression, the cost is
  # proportional to duration alone and is independent of how many blocks a track
  # owns.
  #
  # Samples are emitted in fixed-size chunks so memory stays bounded no matter how
  # long the recording is.
  class GainEnvelope
    CHUNK_SAMPLES = 1 << 20

    # @param resample_rate [Integer] sample rate of the envelope, in Hz; must match
    #   the rate the track is resampled to so +amultiply+ lines the two up.
    # @param buffer_s [Float] padding, in seconds, added to each side of every
    #   owned block before the ramp is applied.
    # @param fade_s [Float] raised-cosine ramp duration, in seconds, at each block
    #   edge. Zero disables the ramp, giving hard (clicky) block edges.
    def initialize(resample_rate:, buffer_s: 0.0, fade_s: 0.0)
      @resample_rate = resample_rate
      @buffer_s = buffer_s
      @fade_n = (fade_s * resample_rate).round
    end

    # Writes the envelope for +intervals+ covering [0, duration_s) to +path+ and
    # returns the path. Owned blocks are padded and merged so the result is a clean
    # sequence of ramped speech blocks separated by silence.
    def write(path, intervals, duration_s)
      total = (duration_s * @resample_rate).round
      blocks = sample_blocks(intervals, total)
      File.open(path, "wb") do |io|
        offset = 0
        while offset < total
          len = [CHUNK_SAMPLES, total - offset].min
          io.write(chunk(blocks, offset, len).pack("e*"))
          offset += len
        end
      end
      path
    end

    private

    # The gain samples for the window [offset, offset + len): zero everywhere the
    # blocks do not reach, painted up where they do. Blocks outside the window are
    # skipped so the total work is proportional to the owned audio, not the blocks.
    def chunk(blocks, offset, len)
      window_end = offset + len
      samples = Array.new(len, 0.0)
      blocks.each do |start_at, end_at|
        next if end_at <= offset || start_at >= window_end

        paint(samples, offset, start_at, end_at)
      end
      samples
    end

    # Paints one block's gain into the chunk: a flat interior at 1.0 with a
    # raised-cosine ramp easing in at the start and out at the end. The ramp is
    # clamped to half the block so very short blocks still fade cleanly.
    def paint(samples, offset, start_at, end_at)
      fade = [@fade_n, (end_at - start_at) / 2].min
      fill_interior(samples, offset, start_at, end_at)
      return if fade.zero?

      fade.times do |step|
        value = ramp(step, fade)
        soften(samples, start_at + step - offset, value)
        soften(samples, end_at - 1 - step - offset, value)
      end
    end

    # Fills the part of [start_at, end_at) that lands in this chunk with 1.0.
    def fill_interior(samples, offset, start_at, end_at)
      lo = [start_at - offset, 0].max
      hi = [end_at - offset, samples.length].min
      samples.fill(1.0, lo, hi - lo) if hi > lo
    end

    # Lowers a single in-chunk sample to +value+. A ramp leg only ever lowers a
    # sample, so the in and out legs of a short block keep the smaller value where
    # they overlap instead of fighting.
    def soften(samples, index, value)
      return if index.negative? || index >= samples.length

      samples[index] = value if value < samples[index]
    end

    # Raised-cosine (Hann) ramp: 0 at the block edge rising to 1 over +fade+ steps.
    def ramp(step, fade)
      0.5 - (0.5 * Math.cos(Math::PI * step / fade))
    end

    # Owned intervals as merged, padded, non-empty [start_sample, end_sample)
    # ranges clamped to [0, total], in timeline order.
    def sample_blocks(intervals, total)
      ranges = intervals.map do |interval|
        start_at = [((interval.start_at - @buffer_s) * @resample_rate).round, 0].max
        end_at = [((interval.end_at + @buffer_s) * @resample_rate).round, total].min
        [start_at, end_at]
      end
      merge(ranges.sort_by(&:first)).reject { |start_at, end_at| end_at <= start_at }
    end

    # Merges sorted [start, end] ranges that overlap or touch into single ranges.
    def merge(ranges)
      ranges.each_with_object([]) do |(start_at, end_at), merged|
        if merged.any? && start_at <= merged.last[1]
          merged.last[1] = [merged.last[1], end_at].max
        else
          merged << [start_at, end_at]
        end
      end
    end
  end
end
