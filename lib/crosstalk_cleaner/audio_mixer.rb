# frozen_string_literal: true

require "tempfile"

require_relative "interval_expression"

module CrosstalkCleaner
  # Builds the ffmpeg invocation that collapses the multi-track recording into a
  # single crosstalk-free file. Each track is muted everywhere except the
  # intervals it owns (per OverlapResolver), then all tracks are summed. Because
  # ownership intervals never overlap, the sum is the single active speaker.
  class AudioMixer
    RESAMPLE_RATE = 48_000
    CHANNEL_LAYOUT = "stereo"

    # Frame size, in samples, forced before the volume filter when fading. The
    # volume filter re-evaluates its expression only once per frame, so short
    # frames are needed for the gain ramp to be smooth enough to avoid clicks.
    FADE_FRAME_SAMPLES = 32

    # @param ffmpeg [Ffmpeg] the ffmpeg shell-out wrapper
    # @param buffer_s [Float] padding, in seconds, added to each side of every
    #   owned block.
    # @param fade_s [Float] gain-ramp duration, in seconds, applied at each side
    #   of every owned block so a speaker eases in/out instead of cutting in
    #   abruptly (which clicks). Zero disables the ramp (a hard gate).
    # @param resample_rate [Integer] sample rate every track is resampled to
    #   before mixing, in Hz.
    # @param channel_layout [String] channel layout every track is conformed to
    #   before mixing (e.g. "stereo", "mono").
    def initialize(ffmpeg, buffer_s: 0.0, fade_s: 0.0, resample_rate: RESAMPLE_RATE, channel_layout: CHANNEL_LAYOUT)
      @ffmpeg = ffmpeg
      @buffer_s = buffer_s
      @fade_s = fade_s
      @resample_rate = resample_rate
      @channel_layout = channel_layout
    end

    # @param inputs [Array<String>] input file paths, in priority order
    # @param ownership_by_track [Hash{Integer=>Array<Interval>}] owned intervals
    # @param output [String] intermediate output path
    # @param gains [Hash{Integer=>Float}] per-track gain in dB to apply (from the
    #   volume normalizer); tracks absent or zero are left at their original level.
    #
    # The filtergraph grows with the number of speech intervals and would overflow
    # the OS argv limit (Errno::E2BIG) if passed inline, so it is written to a
    # temp script file and handed to ffmpeg via -filter_complex_script.
    def render(inputs, ownership_by_track, output, gains: {})
      Tempfile.create(["crosstalk_filter", ".txt"]) do |script|
        script.write(filter_complex(inputs.size, ownership_by_track, gains))
        script.flush
        @ffmpeg.run(build_args(inputs, script.path, output))
      end
      output
    end

    # Constructs the ffmpeg argument vector (without the binary name). The
    # filtergraph is referenced by file path rather than inlined.
    def build_args(inputs, filter_script_path, output)
      args = []
      inputs.each { |path| args.push("-i", path) }
      args.push("-filter_complex_script", filter_script_path)
      args.push("-map", "[mix]", output)
    end

    # Builds the full -filter_complex string for the given number of tracks.
    def filter_complex(track_count, ownership_by_track, gains = {})
      chains = (0...track_count).map do |index|
        intervals = ownership_by_track.fetch(index, [])
        "[#{index}:a]aresample=#{@resample_rate},aformat=channel_layouts=#{@channel_layout}," \
          "#{gate_filter(intervals)}#{gain_filter(gains[index])}[a#{index}]"
      end
      labels = (0...track_count).map { |index| "[a#{index}]" }.join
      chains.join(";") + ";#{labels}amix=inputs=#{track_count}:normalize=0[mix]"
    end

    # The per-track filter(s) that silence the track outside its owned intervals.
    # With a fade, the gain ramps smoothly via a volume envelope (preceded by
    # asetnsamples so the ramp is evaluated finely enough to stay click-free);
    # without one it is the original instantaneous mute gate.
    def gate_filter(intervals)
      return "volume=0:enable='#{mute_expression(intervals)}'" if @fade_s <= 0

      "asetnsamples=n=#{FADE_FRAME_SAMPLES}:p=0,volume='#{gain_expression(intervals)}':eval=frame"
    end

    # ffmpeg enable expression that is true when the track should be muted, i.e.
    # whenever the instant is NOT inside one of the owned intervals.
    def mute_expression(intervals)
      return "1" if intervals.empty?

      "not(#{IntervalExpression.owned(intervals, @buffer_s)})"
    end

    # Volume value (a gain in [0,1]) for a faded track: a smooth envelope that
    # eases in/out at each owned block edge, or "0" for a track that owns nothing.
    def gain_expression(intervals)
      return "0" if intervals.empty?

      IntervalExpression.envelope(intervals, @buffer_s, @fade_s)
    end

    # Trailing volume filter that applies a normalization gain, or "" when there
    # is no (or a zero) gain so the chain is byte-identical to the un-normalized one.
    def gain_filter(gain)
      return "" if gain.nil? || gain.zero?

      format(",volume=%<gain>.2fdB", gain: gain)
    end
  end
end
