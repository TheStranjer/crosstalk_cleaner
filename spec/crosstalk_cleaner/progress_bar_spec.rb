# frozen_string_literal: true

require "stringio"

RSpec.describe CrosstalkCleaner::ProgressBar do
  let(:io) { StringIO.new }

  context "when attached to a TTY" do
    before { allow(io).to receive(:tty?).and_return(true) }

    it "draws an in-place bar with a percentage and the raw sample counts" do
      bar = described_class.new(io, "Collapsing 3 tracks", 1000)
      bar.start
      bar.update(250)
      expect(io.string).to include("Collapsing 3 tracks")
      expect(io.string).to include(" 25%")
      expect(io.string).to include("(250/1,000 samples)")
      expect(io.string).to include("\r") # rewrites the line in place
    end

    it "snaps to 100% on a fresh line when finished" do
      bar = described_class.new(io, "Mixing", 1000)
      bar.start
      bar.finish
      expect(io.string).to include("100%")
      expect(io.string).to include("(1,000/1,000 samples)")
      expect(io.string).to end_with("\n")
    end

    it "never reports past 100% even if handed more than the total" do
      bar = described_class.new(io, "Mixing", 100)
      bar.start
      bar.update(150)
      expect(io.string).to include("100%")
      expect(io.string).to include("(100/100 samples)")
    end
  end

  context "when not attached to a TTY" do
    it "announces the label once and emits no control characters" do
      bar = described_class.new(io, "Collapsing 2 tracks", 1000)
      bar.start
      bar.update(500)
      bar.finish
      expect(io.string).to eq("Collapsing 2 tracks\n")
    end
  end
end
