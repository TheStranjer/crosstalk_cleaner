# frozen_string_literal: true

RSpec.describe CrosstalkCleaner::IntervalExpression do
  describe ".owned" do
    it "is true while t is inside any padded interval" do
      expr = described_class.owned([interval(1.0, 2.0, 0), interval(4.0, 5.5, 0)], 0.1)
      expect(expr).to eq("between(t,0.900,2.100)+between(t,3.900,5.600)")
    end

    it "clamps the padded start at zero" do
      expr = described_class.owned([interval(0.05, 2.0, 0)], 0.1)
      expect(expr).to eq("between(t,0.000,2.100)")
    end
  end

  describe ".envelope" do
    it "ramps in and out over the fade at each padded block edge" do
      expr = described_class.envelope([interval(1.0, 2.0, 0)], 0.1, 0.01)
      expect(expr).to eq("min(1,clip(min((t-0.900)/0.010,(2.100-t)/0.010),0,1))")
    end

    it "sums a ramp per interval, clamped to unity" do
      expr = described_class.envelope([interval(1.0, 2.0, 0), interval(4.0, 5.5, 0)], 0.1, 0.01)
      expect(expr).to eq(
        "min(1," \
        "clip(min((t-0.900)/0.010,(2.100-t)/0.010),0,1)+" \
        "clip(min((t-3.900)/0.010,(5.600-t)/0.010),0,1))"
      )
    end

    it "clamps the padded start at zero" do
      expr = described_class.envelope([interval(0.05, 2.0, 0)], 0.1, 0.01)
      expect(expr).to eq("min(1,clip(min((t-0.000)/0.010,(2.100-t)/0.010),0,1))")
    end

    it "falls back to the binary owned expression when the fade is zero" do
      intervals = [interval(1.0, 2.0, 0)]
      expect(described_class.envelope(intervals, 0.1, 0.0))
        .to eq(described_class.owned(intervals, 0.1))
    end
  end
end
