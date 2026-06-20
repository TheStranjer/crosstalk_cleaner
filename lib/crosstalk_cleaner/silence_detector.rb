# frozen_string_literal: true

require_relative "interval"

module CrosstalkCleaner
  # Turns a track into a list of speech Intervals by detecting silence with ffmpeg
  # and inverting it across the track duration.
  class SilenceDetector
    SILENCE_START = /silence_start:\s*(-?\d+(?:\.\d+)?)/
    SILENCE_END = /silence_end:\s*(-?\d+(?:\.\d+)?)/

    def initialize(ffmpeg)
      @ffmpeg = ffmpeg
    end

    # @return [Array<Interval>] speech intervals for the track at +track_index+.
    def speech_intervals(path, track_index)
      duration = @ffmpeg.duration(path)
      output = @ffmpeg.silencedetect(path)
      silences = parse_silences(output, duration)
      invert(silences, duration, track_index)
    end

    # Parses raw silencedetect stderr into a sorted list of [start, end] silence
    # pairs, clamped to [0, duration]. Exposed for direct testing.
    def parse_silences(text, duration)
      starts = text.scan(SILENCE_START).map { |m| m.first.to_f }
      ends = text.scan(SILENCE_END).map { |m| m.first.to_f }

      pairs = starts.zip(ends).map do |start_at, end_at|
        [clamp(start_at, duration), clamp(end_at || duration, duration)]
      end
      pairs.reject { |start_at, end_at| end_at <= start_at }.sort_by(&:first)
    end

    # Inverts silence pairs into speech intervals across [0, duration].
    def invert(silences, duration, track_index)
      intervals = []
      cursor = 0.0
      silences.each do |start_at, end_at|
        intervals << build(cursor, start_at, track_index) if start_at > cursor
        cursor = [cursor, end_at].max
      end
      intervals << build(cursor, duration, track_index) if duration > cursor
      intervals
    end

    private

    def build(start_at, end_at, track_index)
      Interval.new(start_at: start_at, end_at: end_at, track_index: track_index)
    end

    def clamp(value, duration)
      value.clamp(0.0, duration)
    end
  end
end
