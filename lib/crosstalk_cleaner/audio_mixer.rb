# frozen_string_literal: true

require "tempfile"

module CrosstalkCleaner
  # Builds the ffmpeg invocation that collapses the multi-track recording into a
  # single crosstalk-free file. Each track is muted everywhere except the
  # intervals it owns (per OverlapResolver), then all tracks are summed. Because
  # ownership intervals never overlap, the sum is the single active speaker.
  class AudioMixer
    def initialize(ffmpeg)
      @ffmpeg = ffmpeg
    end

    # @param inputs [Array<String>] input file paths, in priority order
    # @param ownership_by_track [Hash{Integer=>Array<Interval>}] owned intervals
    # @param output [String] intermediate output path
    #
    # The filtergraph grows with the number of speech intervals and would overflow
    # the OS argv limit (Errno::E2BIG) if passed inline, so it is written to a
    # temp script file and handed to ffmpeg via -filter_complex_script.
    def render(inputs, ownership_by_track, output)
      Tempfile.create(["crosstalk_filter", ".txt"]) do |script|
        script.write(filter_complex(inputs.size, ownership_by_track))
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
    def filter_complex(track_count, ownership_by_track)
      chains = (0...track_count).map do |index|
        intervals = ownership_by_track.fetch(index, [])
        "[#{index}:a]aresample=48000,aformat=channel_layouts=stereo," \
          "volume=0:enable='#{mute_expression(intervals)}'[a#{index}]"
      end
      labels = (0...track_count).map { |index| "[a#{index}]" }.join
      chains.join(";") + ";#{labels}amix=inputs=#{track_count}:normalize=0[mix]"
    end

    # ffmpeg enable expression that is true when the track should be muted, i.e.
    # whenever the instant is NOT inside one of the owned intervals.
    def mute_expression(intervals)
      return "1" if intervals.empty?

      owned = intervals.map do |interval|
        format("between(t,%<start>.3f,%<end>.3f)", start: interval.start_at, end: interval.end_at)
      end.join("+")
      "not(#{owned})"
    end
  end
end
