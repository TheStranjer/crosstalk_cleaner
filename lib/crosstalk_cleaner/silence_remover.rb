# frozen_string_literal: true

module CrosstalkCleaner
  # Builds the ffmpeg invocation that trims dead silence. Any silent stretch
  # longer than the configured limit is cut down so at most +limit_s+ seconds of
  # silence remains.
  class SilenceRemover
    NOISE_FLOOR = "-30dB"

    # @param ffmpeg [Ffmpeg] the ffmpeg shell-out wrapper
    # @param noise_floor [String] amplitude below which audio counts as silence
    #   (any ffmpeg volume expression, e.g. "-30dB").
    # @param declick [Boolean] whether to repair the splice transients
    #   silenceremove leaves behind (see #silence_filter). On by default.
    def initialize(ffmpeg, noise_floor: NOISE_FLOOR, declick: true)
      @ffmpeg = ffmpeg
      @noise_floor = noise_floor
      @declick = declick
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
    # up to stop_duration seconds of it. It splices the kept audio with a hard cut,
    # though, which clicks audibly whenever a cut lands in low-level room tone
    # rather than true digital silence (a pause or breath inside a speaker's turn).
    # adeclick repairs those splice transients in one pass, so it is appended
    # unless declicking is switched off.
    def silence_filter(limit_s)
      remove = format("silenceremove=stop_periods=-1:stop_duration=%<limit>.3f:stop_threshold=%<floor>s",
                      limit: limit_s, floor: @noise_floor)
      @declick ? "#{remove},adeclick" : remove
    end
  end
end
