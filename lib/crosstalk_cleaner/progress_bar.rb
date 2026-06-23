# frozen_string_literal: true

module CrosstalkCleaner
  # A single-line, in-place progress indicator for long ffmpeg renders. On a TTY
  # it draws an ANSI bar that rewrites itself in place via carriage return;
  # everywhere else (pipes, log files, the StringIO used in tests) it degrades to
  # a one-time label line so no control characters leak into captured output.
  class ProgressBar
    BAR_WIDTH = 30

    # @param logger [IO] sink to draw on (typically $stdout)
    # @param label [String] the text shown ahead of the bar
    # @param total [Integer] the count that represents 100%
    # @param width [Integer] bar width in characters
    def initialize(logger, label, total, width: BAR_WIDTH)
      @logger = logger
      @label = label
      @total = total.to_i
      @width = width
      @tty = logger.respond_to?(:tty?) && logger.tty?
      @started = false
    end

    # Draws the initial 0% state on a TTY, or prints the bare label once
    # otherwise so the stage is still announced in non-interactive output.
    def start
      @started = true
      @tty ? redraw(0) : @logger.puts(@label)
    end

    # Redraws the bar at +current+ done. A no-op before #start or off a TTY.
    def update(current)
      return unless @started && @tty

      redraw(current)
    end

    # Snaps the bar to 100% and moves to a fresh line. A no-op off a TTY.
    def finish
      return unless @started && @tty

      redraw(@total)
      @logger.print("\n")
      flush
    end

    private

    # Rewrites the current line: carriage return, clear-to-end-of-line, new text.
    def redraw(current)
      @logger.print("\r\e[2K#{line(current.clamp(0, @total))}")
      flush
    end

    def line(current)
      ratio = @total.zero? ? 1.0 : current.to_f / @total
      filled = (ratio * @width).round
      bar = ("█" * filled) + ("░" * (@width - filled))
      format("%<label>s [%<bar>s] %<pct>3d%% (%<done>s/%<total>s samples)",
             label: @label, bar: bar, pct: (ratio * 100).round,
             done: commas(current), total: commas(@total))
    end

    def flush
      @logger.flush if @logger.respond_to?(:flush)
    end

    # 12345678 => "12,345,678"
    def commas(number)
      number.to_s.reverse.gsub(/(\d{3})(?=\d)/, "\\1,").reverse
    end
  end
end
