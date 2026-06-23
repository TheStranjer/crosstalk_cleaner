# frozen_string_literal: true

module CrosstalkCleaner
  # Builds the ffmpeg invocation that trims dead silence. Any silent stretch
  # longer than the configured limit is cut down so at most +limit_s+ seconds of
  # silence remains.
  class SilenceRemover
    NOISE_FLOOR = "-30dB"

    # Number of adeclick passes chained after silenceremove (see #silence_filter).
    DECLICK_PASSES = 2

    # @param ffmpeg [Ffmpeg] the ffmpeg shell-out wrapper
    # @param noise_floor [String] amplitude below which audio counts as silence
    #   (any ffmpeg volume expression, e.g. "-30dB").
    # @param declick [Boolean] whether to repair the splice transients
    #   silenceremove leaves behind (see #silence_filter). On by default.
    # @param buffer_s [Float] the mix's block buffer, in seconds. A word's soft
    #   onset and decay sit below the noise floor, so silenceremove counts them as
    #   silence and would chop them straight back off even though the mixer's block
    #   buffer deliberately padded them in. Keeping this much silence at the
    #   trailing edge of every trimmed gap (see #silence_filter) preserves that
    #   padded onset, so BLOCK_BUFFER actually survives into the final file.
    def initialize(ffmpeg, noise_floor: NOISE_FLOOR, declick: true, buffer_s: 0.0)
      @ffmpeg = ffmpeg
      @noise_floor = noise_floor
      @declick = declick
      @buffer_s = buffer_s
    end

    # @param input [String] the crosstalk-cleaned intermediate file
    # @param output [String] the final output path
    # @param limit_s [Float] maximum silence duration to keep, in seconds
    #
    # An optional block is forwarded to Ffmpeg#run, which calls it with the output
    # time written so far (in seconds) as the trim progresses.
    def render(input, output, limit_s, &)
      @ffmpeg.run(build_args(input, output, limit_s), &)
      output
    end

    def build_args(input, output, limit_s)
      ["-i", input, "-af", silence_filter(limit_s), output]
    end

    # silenceremove with stop_periods=-1 trims silence wherever it occurs, keeping
    # up to stop_duration seconds of it at the leading edge of each gap (the decay
    # right after a speaker stops). stop_silence keeps the symmetric amount at the
    # trailing edge (the soft onset right before the next speaker starts); without
    # it that onset is always chopped, which is why BLOCK_BUFFER appeared to do
    # nothing to word starts. It splices the kept audio with a hard cut, though,
    # which clicks audibly whenever a cut lands in low-level room tone rather than
    # true digital silence (a pause or breath inside a speaker's turn).
    #
    # adeclick repairs those splice transients. A single pass leaves the largest
    # steps only partly smoothed, so two passes are chained: measured on real
    # multi-track audio this drops the residual clicks to the recording's own
    # transient floor while staying inaudibly close (-71 dB) to the speech itself.
    # Both passes are skipped when declicking is switched off.
    def silence_filter(limit_s)
      remove = format("silenceremove=stop_periods=-1:stop_duration=%<limit>.3f:stop_threshold=%<floor>s%<keep>s",
                      limit: limit_s, floor: @noise_floor, keep: stop_silence)
      return remove unless @declick

      ([remove] + (["adeclick"] * DECLICK_PASSES)).join(",")
    end

    # The +stop_silence+ clause that keeps the block buffer's worth of silence at
    # the trailing edge of every trimmed gap, or "" when no buffer is configured
    # (so the emitted filter is byte-identical to the un-buffered one).
    def stop_silence
      return "" if @buffer_s <= 0

      format(":stop_silence=%<buffer>.3f", buffer: @buffer_s)
    end
  end
end
