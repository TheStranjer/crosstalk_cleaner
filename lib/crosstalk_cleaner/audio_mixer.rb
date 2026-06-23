# frozen_string_literal: true

require "fileutils"
require "tempfile"

require_relative "gain_envelope"

module CrosstalkCleaner
  # Builds the ffmpeg invocation that collapses the multi-track recording into a
  # single crosstalk-free file. Each track is multiplied by a per-track gain
  # envelope (see GainEnvelope) that is 1.0 over the intervals the track owns (per
  # OverlapResolver) and 0.0 elsewhere, then all tracks are summed. Because
  # ownership intervals never overlap, the sum is the single active speaker.
  #
  # The envelope carries a short raised-cosine ramp at every block edge, so a
  # speaker eases in and out instead of switching on with a click. The gate lives
  # in the envelope's sample data and is applied with +amultiply+, which runs at
  # ffmpeg's native frame size; the filtergraph itself stays tiny regardless of how
  # many blocks a track owns, which is what keeps the mix fast.
  class AudioMixer
    RESAMPLE_RATE = 48_000
    CHANNEL_LAYOUT = "stereo"

    # Sample rate the gain envelope is generated at, in Hz. The envelope is a
    # slow-moving gain signal (block edges to the millisecond, fades over ~10ms),
    # so a low rate captures it faithfully; ffmpeg upsamples it to the mix rate
    # before the multiply. Generating it here rather than at the mix rate keeps the
    # temp envelope files ~50x smaller and their generation ~50x faster, which is
    # what stops a long recording from stalling for minutes before ffmpeg starts.
    ENVELOPE_RATE = 1_000

    # @param ffmpeg [Ffmpeg] the ffmpeg shell-out wrapper
    # @param buffer_s [Float] padding, in seconds, added to each side of every
    #   owned block so a speaker is not clipped at the edges.
    # @param fade_s [Float] raised-cosine ramp duration, in seconds, applied at
    #   each side of every owned block so a speaker eases in/out instead of cutting
    #   in abruptly (which clicks). Zero disables the ramp (a hard gate).
    # @param resample_rate [Integer] sample rate every track (and its envelope) is
    #   resampled to before mixing, in Hz.
    # @param channel_layout [String] channel layout every track is conformed to
    #   before mixing (e.g. "stereo", "mono").
    def initialize(ffmpeg, buffer_s: 0.0, fade_s: 0.0, resample_rate: RESAMPLE_RATE, channel_layout: CHANNEL_LAYOUT)
      @ffmpeg = ffmpeg
      @resample_rate = resample_rate
      @channel_layout = channel_layout
      @envelope = GainEnvelope.new(resample_rate: ENVELOPE_RATE, buffer_s: buffer_s, fade_s: fade_s)
    end

    # @param inputs [Array<String>] input file paths, in priority order
    # @param ownership_by_track [Hash{Integer=>Array<Interval>}] owned intervals
    # @param output [String] intermediate output path
    # @param gains [Hash{Integer=>Float}] per-track gain in dB to apply (from the
    #   volume normalizer); tracks absent or zero are left at their original level.
    #
    # Each owning track gets a gain envelope rendered to a temp file and fed to
    # ffmpeg as an extra raw-float input; the small filtergraph is handed over via
    # -filter_complex_script. An optional block is forwarded to Ffmpeg#run, which
    # calls it with the output time rendered so far (in seconds) as the mix runs.
    def render(inputs, ownership_by_track, output, gains: {}, &progress)
      owned = (0...inputs.size).select { |index| ownership_by_track.fetch(index, []).any? }
      with_envelope_files(inputs, ownership_by_track, owned) do |env_paths|
        Tempfile.create(["crosstalk_filter", ".txt"]) do |script|
          script.write(filter_complex(inputs.size, ownership_by_track, gains))
          script.flush
          @ffmpeg.run(build_args(inputs, env_paths, script.path, output), &progress)
        end
      end
      output
    end

    # Constructs the ffmpeg argument vector (without the binary name): the track
    # inputs, then one raw-float mono input per envelope (in owning-track order, so
    # the input indices line up with #filter_complex), then the filtergraph script.
    def build_args(inputs, env_paths, filter_script_path, output)
      args = []
      inputs.each { |path| args.push("-i", path) }
      env_paths.each { |path| args.push("-f", "f32le", "-ar", ENVELOPE_RATE.to_s, "-ac", "1", "-i", path) }
      args.push("-filter_complex_script", filter_script_path)
      args.push("-map", "[mix]", output)
    end

    # Builds the full -filter_complex string for the given number of tracks. Each
    # owning track is multiplied by its envelope input; tracks that own nothing are
    # simply muted. The envelope inputs follow the track inputs, one per owning
    # track in ascending index order.
    def filter_complex(track_count, ownership_by_track, gains = {})
      env_index = env_indices(track_count, ownership_by_track)
      chains = (0...track_count).flat_map do |index|
        track_chains(index, env_index[index], gains[index])
      end
      labels = (0...track_count).map { |index| "[a#{index}]" }.join
      "#{chains.join(";")};#{labels}amix=inputs=#{track_count}:normalize=0[mix]"
    end

    private

    # The filterchain(s) for one track: a muted chain when it owns nothing, or its
    # resampled audio multiplied by its (stereo-conformed) envelope otherwise.
    def track_chains(index, env_input, gain)
      return ["#{base_chain(index)},volume=0[a#{index}]"] if env_input.nil?

      ["#{base_chain(index)}[trk#{index}]",
       "[#{env_input}:a]aresample=#{@resample_rate},aformat=channel_layouts=#{@channel_layout}[env#{index}]",
       "[trk#{index}][env#{index}]amultiply#{gain_filter(gain)}[a#{index}]"]
    end

    # Resample/conform the raw input; every track chain starts from this.
    def base_chain(index)
      "[#{index}:a]aresample=#{@resample_rate},aformat=channel_layouts=#{@channel_layout}"
    end

    # Maps each owning track index to the ffmpeg input index of its envelope. The
    # envelopes follow the track inputs, assigned in ascending track order.
    def env_indices(track_count, ownership_by_track)
      next_input = track_count
      (0...track_count).each_with_object({}) do |index, map|
        next if ownership_by_track.fetch(index, []).empty?

        map[index] = next_input
        next_input += 1
      end
    end

    # Renders an envelope temp file for each owning track (in ascending index
    # order), yields their paths, and removes them afterward.
    def with_envelope_files(inputs, ownership_by_track, owned)
      paths = owned.map do |index|
        file = Tempfile.create(["crosstalk_env_#{index}_", ".f32"])
        file.close
        @envelope.write(file.path, ownership_by_track.fetch(index, []), @ffmpeg.duration(inputs[index]))
      end
      yield paths
    ensure
      paths&.each { |path| FileUtils.rm_f(path) }
    end

    # Trailing volume filter that applies a normalization gain, or "" when there
    # is no (or a zero) gain so the chain is byte-identical to the un-normalized one.
    def gain_filter(gain)
      return "" if gain.nil? || gain.zero?

      format(",volume=%<gain>.2fdB", gain: gain)
    end
  end
end
