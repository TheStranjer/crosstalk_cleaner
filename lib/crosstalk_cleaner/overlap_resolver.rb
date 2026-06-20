# frozen_string_literal: true

require_relative "interval"

module CrosstalkCleaner
  # Resolves crosstalk between tracks. Given the speech intervals of every track,
  # it decides which single track "owns" each instant of the timeline.
  #
  # Rule: the owner is whoever started speaking first. If two speakers started
  # within +tolerance_s+ of each other they are treated as a tie, broken by track
  # priority (the order the tracks were supplied on the command line; index 0 is
  # the top priority and wins).
  class OverlapResolver
    def initialize(tolerance_s:)
      @tolerance_s = tolerance_s
    end

    # @param track_intervals [Array<Array<Interval>>] speech intervals per track,
    #   indexed by priority (element 0 == highest priority track).
    # @return [Array<Interval>] non-overlapping ownership intervals, sorted by time.
    def resolve(track_intervals)
      segments = track_intervals.flatten
      return [] if segments.empty?

      boundaries = boundaries_for(segments)
      owned = elementary_owners(boundaries, segments)
      merge(owned)
    end

    private

    def boundaries_for(segments)
      points = segments.flat_map { |seg| [seg.start_at, seg.end_at] }
      points.uniq.sort
    end

    # For each elementary slice between adjacent boundaries, find the owning track.
    # Returns [start, end, track_index] triples for slices that have an owner.
    def elementary_owners(boundaries, segments)
      result = []
      boundaries.each_cons(2) do |start_at, end_at|
        next if end_at <= start_at

        midpoint = (start_at + end_at) / 2.0
        active = segments.select { |seg| seg.cover?(midpoint) }
        next if active.empty?

        result << [start_at, end_at, winner(active).track_index]
      end
      result
    end

    # Picks the winning segment among those active at an instant.
    def winner(active)
      earliest = active.min_by(&:start_at).start_at
      contenders = active.select { |seg| seg.start_at - earliest <= @tolerance_s }
      contenders.min_by(&:track_index)
    end

    # Merges adjacent slices owned by the same track into single intervals.
    def merge(owned)
      owned.each_with_object([]) do |(start_at, end_at, track_index), acc|
        last = acc.last
        if last && last.track_index == track_index && (start_at - last.end_at).abs < 1e-9
          acc[-1] = Interval.new(start_at: last.start_at, end_at: end_at, track_index: track_index)
        else
          acc << Interval.new(start_at: start_at, end_at: end_at, track_index: track_index)
        end
      end
    end
  end
end
