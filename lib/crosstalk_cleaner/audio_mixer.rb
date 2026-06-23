# frozen_string_literal: true

require "tempfile"

module CrosstalkCleaner
  # Builds the ffmpeg invocation that collapses the multi-track recording into a
  # single crosstalk-free file. Each track keeps only the intervals it owns (per
  # OverlapResolver) and is silent elsewhere; the tracks are then summed. Because
  # ownership intervals never overlap, the sum is the single active speaker.
  #
  # Each owned block is cut out with +atrim+, eased in/out with the native
  # +afade+ filter (sample-accurate, so no click) and the gaps are filled with
  # the same audio muted, so a track is rebuilt at its original timeline by a
  # sequential +concat+ rather than a per-sample volume envelope. concat runs at
  # ffmpeg's native frame size, which is what keeps the mix fast.
  class AudioMixer
    RESAMPLE_RATE = 48_000
    CHANNEL_LAYOUT = "stereo"

    # @param ffmpeg [Ffmpeg] the ffmpeg shell-out wrapper
    # @param buffer_s [Float] padding, in seconds, added to each side of every
    #   owned block so a speaker is not clipped at the edges.
    # @param fade_s [Float] gain-ramp duration, in seconds, applied at each side
    #   of every owned block so a speaker eases in/out instead of cutting in
    #   abruptly (which clicks). Zero disables the ramp (a hard cut).
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
    #
    # An optional block is forwarded to Ffmpeg#run, which calls it with the output
    # time rendered so far (in seconds) as the mix progresses.
    def render(inputs, ownership_by_track, output, gains: {}, &progress)
      Tempfile.create(["crosstalk_filter", ".txt"]) do |script|
        script.write(filter_complex(inputs.size, ownership_by_track, gains))
        script.flush
        @ffmpeg.run(build_args(inputs, script.path, output), &progress)
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
        track_chain(index, ownership_by_track.fetch(index, []), gains[index])
      end
      labels = (0...track_count).map { |index| "[a#{index}]" }.join
      "#{chains.join(";")};#{labels}amix=inputs=#{track_count}:normalize=0[mix]"
    end

    # Padded, non-overlapping owned blocks for a track, as [start, end] pairs in
    # timeline order. Adjacent blocks whose padding overlaps are merged so the
    # track is a clean sequence of speech blocks separated by silence.
    def padded_blocks(intervals)
      padded = intervals.map { |iv| [[iv.start_at - @buffer_s, 0.0].max, iv.end_at + @buffer_s] }
      merge_ranges(padded.sort_by(&:first))
    end

    private

    # The filterchain(s) that rebuild a single track: its owned blocks, faded and
    # interleaved with muted gaps, concatenated back onto the original timeline.
    # A track that owns nothing is simply silenced in full.
    def track_chain(index, intervals, gain)
      blocks = padded_blocks(intervals)
      return "#{base_chain(index)},volume=0[a#{index}]" if blocks.empty?

      segments = segments_for(blocks)
      return single_segment_chain(index, segments.first, gain) if segments.one?

      split_and_concat(index, segments, gain)
    end

    # Resample/conform the raw input; every chain starts from this.
    def base_chain(index)
      "[#{index}:a]aresample=#{@resample_rate},aformat=channel_layouts=#{@channel_layout}"
    end

    # A track that is one block starting at the very beginning needs no split or
    # concat: trim, fade and (optionally) gain it in a single chain.
    def single_segment_chain(index, segment, gain)
      kind, start_at, end_at = segment
      "#{base_chain(index)},#{segment_filter(kind, start_at, end_at)}#{gain_filter(gain)}[a#{index}]"
    end

    # Split the track into one branch per segment, filter each, and concat them
    # back into a single timeline-accurate stream (gain applied to the whole).
    def split_and_concat(index, segments, gain)
      ins = segments.each_index.map { |j| "[t#{index}_in#{j}]" }
      outs = segments.each_index.map { |j| "[t#{index}_seg#{j}]" }
      branches = segments.each_with_index.map do |(kind, start_at, end_at), j|
        "#{ins[j]}#{segment_filter(kind, start_at, end_at)}#{outs[j]}"
      end
      split = "#{base_chain(index)},asplit=#{segments.size}#{ins.join}"
      concat = "#{outs.join}concat=n=#{segments.size}:v=0:a=1#{gain_filter(gain)}[a#{index}]"
      [split, *branches, concat].join(";")
    end

    # Turns ordered blocks into the [:gap|:block, start, end] segment list that
    # tiles the timeline from zero up to the last block (no trailing silence; the
    # mix already runs to the longest track).
    def segments_for(blocks)
      segments = []
      prev_end = 0.0
      blocks.each do |start_at, end_at|
        segments << [:gap, prev_end, start_at] if start_at > prev_end
        segments << [:block, start_at, end_at]
        prev_end = end_at
      end
      segments
    end

    # The per-segment filter: a muted slice for a gap, or a trimmed, faded slice
    # for an owned block. Resetting PTS lets concat lay the slices end to end.
    def segment_filter(kind, start_at, end_at)
      trim = "atrim=start=#{fmt(start_at)}:end=#{fmt(end_at)},asetpts=PTS-STARTPTS"
      return "#{trim},volume=0" if kind == :gap

      "#{trim}#{fade_filter(end_at - start_at)}"
    end

    # The fade-in/out pair for an owned block of the given duration, or "" when
    # fading is disabled. The ramp never exceeds the block, so very short blocks
    # still fade cleanly instead of erroring on a negative offset.
    def fade_filter(duration)
      return "" if @fade_s <= 0

      fade = [@fade_s, duration].min
      out_start = [duration - fade, 0.0].max
      ",afade=t=in:st=#{fmt(0.0)}:d=#{fmt(fade)},afade=t=out:st=#{fmt(out_start)}:d=#{fmt(fade)}"
    end

    # Trailing volume filter that applies a normalization gain, or "" when there
    # is no (or a zero) gain so the chain is byte-identical to the un-normalized one.
    def gain_filter(gain)
      return "" if gain.nil? || gain.zero?

      format(",volume=%<gain>.2fdB", gain: gain)
    end

    # Merges sorted [start, end] ranges that overlap or touch into single ranges.
    def merge_ranges(ranges)
      ranges.each_with_object([]) do |(start_at, end_at), merged|
        if merged.any? && start_at <= merged.last[1]
          merged.last[1] = [merged.last[1], end_at].max
        else
          merged << [start_at, end_at]
        end
      end
    end

    def fmt(value)
      format("%<value>.3f", value: value)
    end
  end
end
