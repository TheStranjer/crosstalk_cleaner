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
end
