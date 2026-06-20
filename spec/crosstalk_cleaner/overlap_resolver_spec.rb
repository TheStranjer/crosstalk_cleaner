# frozen_string_literal: true

RSpec.describe CrosstalkCleaner::OverlapResolver do
  subject(:resolver) { described_class.new(tolerance_s: 0.3) }

  it "returns nothing when there is no speech" do
    expect(resolver.resolve([[], []])).to eq([])
  end

  it "passes a lone segment through unchanged" do
    result = resolver.resolve([[interval(0.0, 5.0, 0)]])
    expect(result).to eq([interval(0.0, 5.0, 0)])
  end

  it "keeps non-overlapping segments from different tracks" do
    result = resolver.resolve([[interval(0.0, 2.0, 0)], [interval(3.0, 5.0, 1)]])
    expect(result).to eq([interval(0.0, 2.0, 0), interval(3.0, 5.0, 1)])
  end

  it "gives the floor to whoever started first, well outside tolerance" do
    track0 = [interval(0.0, 10.0, 0)]
    track1 = [interval(5.0, 15.0, 1)]
    result = resolver.resolve([track0, track1])
    expect(result).to eq([interval(0.0, 10.0, 0), interval(10.0, 15.0, 1)])
  end

  it "lets a clearly-earlier lower-priority track win over a later higher-priority one" do
    # track1 starts a full second before track0, far outside the 300ms tolerance.
    track0 = [interval(1.0, 10.0, 0)]
    track1 = [interval(0.0, 10.0, 1)]
    result = resolver.resolve([track0, track1])
    expect(result).to eq([interval(0.0, 10.0, 1)])
  end

  it "breaks near-simultaneous starts by priority within tolerance" do
    # track1 starts 200ms before track0: inside tolerance, so priority wins the overlap.
    track0 = [interval(0.2, 10.0, 0)]
    track1 = [interval(0.0, 10.0, 1)]
    result = resolver.resolve([track0, track1])
    expect(result).to eq([interval(0.0, 0.2, 1), interval(0.2, 10.0, 0)])
  end

  it "breaks exactly simultaneous starts by priority" do
    track0 = [interval(0.0, 10.0, 0)]
    track1 = [interval(0.0, 10.0, 1)]
    result = resolver.resolve([track0, track1])
    expect(result).to eq([interval(0.0, 10.0, 0)])
  end

  it "fully suppresses crosstalk nested inside another speaker's turn" do
    track0 = [interval(0.0, 10.0, 0)]
    track1 = [interval(3.0, 4.0, 1)]
    result = resolver.resolve([track0, track1])
    expect(result).to eq([interval(0.0, 10.0, 0)])
  end

  it "merges adjacent slices owned by the same track" do
    track0 = [interval(0.0, 5.0, 0), interval(5.0, 10.0, 0)]
    result = resolver.resolve([track0])
    expect(result).to eq([interval(0.0, 10.0, 0)])
  end

  it "hands the floor back after the first speaker stops" do
    track0 = [interval(0.0, 4.0, 0)]
    track1 = [interval(2.0, 8.0, 1)]
    track2 = [interval(6.0, 12.0, 2)]
    result = resolver.resolve([track0, track1, track2])
    expect(result).to eq([
                           interval(0.0, 4.0, 0),
                           interval(4.0, 8.0, 1),
                           interval(8.0, 12.0, 2)
                         ])
  end

  it "respects a widened tolerance" do
    wide = described_class.new(tolerance_s: 2.0)
    track0 = [interval(1.5, 10.0, 0)]
    track1 = [interval(0.0, 10.0, 1)]
    # 1.5s gap is now within tolerance, so the higher-priority track0 wins the overlap.
    result = wide.resolve([track0, track1])
    expect(result).to eq([interval(0.0, 1.5, 1), interval(1.5, 10.0, 0)])
  end
end
