# frozen_string_literal: true

RSpec.describe CrosstalkCleaner::Interval do
  subject(:iv) { interval(1.0, 3.0, 2) }

  it "exposes its attributes as floats" do
    expect(iv.start_at).to eq(1.0)
    expect(iv.end_at).to eq(3.0)
    expect(iv.track_index).to eq(2)
  end

  it "computes duration" do
    expect(iv.duration).to eq(2.0)
  end

  it "rejects inverted bounds" do
    expect { interval(3.0, 1.0, 0) }.to raise_error(ArgumentError)
  end

  describe "#empty?" do
    it "is true for a zero-length interval" do
      expect(interval(2.0, 2.0, 0)).to be_empty
    end

    it "is false for a positive-length interval" do
      expect(iv).not_to be_empty
    end
  end

  describe "#cover?" do
    it "covers the start instant" do
      expect(iv.cover?(1.0)).to be(true)
    end

    it "is half-open at the end" do
      expect(iv.cover?(3.0)).to be(false)
    end

    it "rejects instants before the start" do
      expect(iv.cover?(0.5)).to be(false)
    end
  end

  describe "equality and hashing" do
    it "is equal to an identical interval" do
      expect(iv).to eq(interval(1.0, 3.0, 2))
    end

    it "differs when any field differs" do
      expect(iv).not_to eq(interval(1.0, 3.0, 1))
    end

    it "is not equal to a non-interval" do
      expect(iv == "nope").to be(false)
    end

    it "hashes equal intervals together" do
      expect(iv.hash).to eq(interval(1.0, 3.0, 2).hash)
    end

    it "can be de-duplicated in a set" do
      expect([iv, interval(1.0, 3.0, 2)].uniq.size).to eq(1)
    end
  end

  it "renders a readable string" do
    expect(iv.to_s).to eq("track=2 [1.000, 3.000)")
  end
end
