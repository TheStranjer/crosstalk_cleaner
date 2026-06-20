# crosstalk_cleaner

A small Ruby tool that takes a **multi-track podcast recording** (one WAV file per
speaker, all sharing the same timeline) and produces a single, cleaned-up WAV
file. It does two things, in order:

1. **Removes crosstalk** — when more than one speaker's microphone is active at
   the same time, only one speaker is kept; the bleed from the others is muted.
2. **Removes dead silence** — any stretch of silence longer than a configurable
   limit is trimmed down to that limit.

It shells out to [`ffmpeg`](https://ffmpeg.org/) / `ffprobe` for all audio work.

## How crosstalk is resolved

Each track is a separate microphone, so when one person talks their voice bleeds
into everyone else's track. To pick the legitimate speaker at any moment the tool:

1. Detects the **speech regions** of every track (via `ffmpeg`'s
   `silencedetect`, inverted into speech intervals).
2. For every instant where two or more tracks are speaking, it decides the single
   owner using this rule:
   - **Whoever started speaking first wins.**
   - If two speakers started **within the crosstalk tolerance** of each other
     (300 ms by default), that's treated as a tie and is **broken by priority** —
     the order you list the files on the command line, with the **first file
     being the top priority**.

Once ownership is decided, every track is muted everywhere except the intervals
it owns, and the tracks are summed into one. Because the ownership intervals
never overlap, the sum is always just the single active speaker.

### Example

```
track A (priority 1): ====------    (speaks 0.0s – 4.0s)
track B (priority 2):   ======      (speaks 2.0s – 8.0s)
track C (priority 3):       ====    (speaks 6.0s – 12.0s)

result:               AAAABBBBCCCC
                      A keeps 0–4 (started first),
                      B keeps 4–8 (took over once A stopped),
                      C keeps 8–12.
```

If A and B had instead started within 300 ms of each other, A (higher priority)
would have won the overlapping region outright.

## Requirements

- Ruby >= 3.3
- `ffmpeg` and `ffprobe` on your `PATH`
- [Bundler](https://bundler.io/) (`gem install bundler`)

## Installation

```sh
bundle install
```

## Usage

```sh
ruby ./crosstalk_cleaner.rb top_user.wav second_user.wav third.wav
```

The input files are given **in priority order** — the first argument is the
highest-priority speaker (it wins crosstalk ties). At least one input is
required.

## Configuration (environment variables)

| Variable                     | Default                                   | Meaning |
| ---------------------------- | ----------------------------------------- | ------- |
| `OUTPUT`                     | `output.wav` in the first input's folder  | Path of the final WAV file. |
| `SILENCE_LIMIT`              | `750`                                      | Maximum amount of silence to keep, in **milliseconds**. Longer silences are cut down to this. |
| `CROSSTALK_TOLERANCE`        | `300`                                      | How close two speakers' start times (in **milliseconds**) must be to count as simultaneous, in which case priority breaks the tie. |
| `BLOCK_BUFFER`               | `100`                                      | Padding, in **milliseconds**, kept on each side of every owned block so a speaker fades in/out instead of cutting in abruptly. |
| `SILENCEDETECT_NOISE`        | `-30dB`                                    | Amplitude below which audio counts as silence when **detecting** speech regions. Any `ffmpeg` volume expression (e.g. `-40dB`, `0.01`). |
| `SILENCEDETECT_MIN_DURATION` | `0.1`                                      | Minimum length, in **seconds**, a quiet stretch must last to be treated as silence during detection. |
| `NOISE_FLOOR`                | `-30dB`                                    | Amplitude below which audio counts as silence when **trimming** dead silence from the final mix. Any `ffmpeg` volume expression. |
| `RESAMPLE_RATE`              | `48000`                                    | Sample rate, in **Hz**, every track is resampled to before mixing. |
| `CHANNEL_LAYOUT`             | `stereo`                                   | Channel layout every track is conformed to before mixing (e.g. `stereo`, `mono`). |
| `FFMPEG_BIN`                 | `ffmpeg`                                   | Path to (or name of) the `ffmpeg` binary to invoke. |
| `FFPROBE_BIN`                | `ffprobe`                                  | Path to (or name of) the `ffprobe` binary to invoke. |

`SILENCE_LIMIT`, `CROSSTALK_TOLERANCE`, `BLOCK_BUFFER` and `RESAMPLE_RATE` must be positive integers;
`SILENCEDETECT_MIN_DURATION` must be a positive number.

### Examples

```sh
# Write to a specific file
OUTPUT=~/episode42.wav ruby ./crosstalk_cleaner.rb host.wav guest.wav

# Keep at most 1.5s of silence, widen the crosstalk tie window to 500ms
SILENCE_LIMIT=1500 CROSSTALK_TOLERANCE=500 ruby ./crosstalk_cleaner.rb a.wav b.wav c.wav

# Treat quieter audio as silence and downmix to mono at 44.1kHz
SILENCEDETECT_NOISE=-45dB NOISE_FLOOR=-45dB RESAMPLE_RATE=44100 CHANNEL_LAYOUT=mono \
  ruby ./crosstalk_cleaner.rb a.wav b.wav
```

## How it works internally

The pipeline is split into small, individually testable pieces under
`lib/crosstalk_cleaner/`:

| Class             | Responsibility |
| ----------------- | -------------- |
| `Config`          | Parses CLI arguments and environment variables. |
| `Ffmpeg`          | The only place that shells out to `ffmpeg`/`ffprobe`. |
| `SilenceDetector` | Runs `silencedetect` and inverts it into speech `Interval`s. |
| `OverlapResolver` | Applies the start-time + tolerance + priority rule to assign each instant an owner. |
| `AudioMixer`      | Builds the `ffmpeg` filtergraph that mutes each track outside its owned intervals and sums them. |
| `SilenceRemover`  | Builds the `ffmpeg` `silenceremove` invocation. |
| `Cleaner`         | Orchestrates the whole pipeline. |
| `CLI`             | Command-line front end and exit codes. |

The crosstalk pass and the silence pass each run as a separate `ffmpeg`
invocation; the crosstalk-cleaned audio is written to a temporary file that is
removed automatically.

## Development

Run the test suite:

```sh
bundle exec rspec
```

Run the linter:

```sh
bundle exec rubocop
```

The project uses [RSpec](https://rspec.info/) for tests (covering every code
path) and [RuboCop](https://rubocop.org/) — with `rubocop-performance` and
`rubocop-rspec` — for a strict style policy.
