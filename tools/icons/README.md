# Icon resource optimization

Everything DreamMaker embeds ends up in `tgstation.rsc`, which every client
downloads. Icons are the largest single block in it: ~2600 `.dmi` files,
~120 MiB of a ~420 MiB archive. `optimize_icons.py` recompresses them with
[oxipng](https://github.com/shssoichiro/oxipng).

The change is **lossless**. Nothing about the icon changes except how its pixels
are deflated: BYOND writes `.dmi` with a fixed filter and a cheap compression
level, and a proper filter search wins roughly a third of the bytes back for
free. Other codebases have done the same for years — BeeStation ships
`tools/DMICompressor`, goonstation ships `tools/oxipng`, vgstation runs optipng
from a pre-commit hook.

## Why the text chunk is the whole story

A `.dmi` is an ordinary PNG spritesheet plus one text chunk. That chunk —
usually `zTXt`, keyword `Description` — holds *all* of the BYOND metadata: the
state list, `dirs`, `frames`, `delay`, `loop`, `rewind`, `movement` and
`hotspot`. Without it the file is a picture with no icon states.

Every PNG tool strips ancillary chunks by default, and losing this one fails
**silently**: the file still opens, still shows the right pixels, and the icon is
dead. So the optimizer never strips (`StripChunks.none()`, the equivalent of
running the CLI with no `--strip`), and it re-reads its own output before
installing it. A candidate is only allowed to replace the original when:

- the decompressed `Description` text matches the original **byte for byte**;
- every other text chunk matches too, with none lost or added;
- the sheet has the same pixel dimensions;
- the decoded RGBA pixels match.

Pixels are compared raw first. If they differ, they are compared again with the
RGB under fully transparent pixels flattened, because alpha optimization and
palette merging legitimately rewrite bytes nothing can render. Any other
difference — or a chunk that fails to parse — rejects the candidate and leaves
the original file untouched; the run reports it and exits non-zero.

## Installing oxipng

```sh
pip install pyoxipng
```

That is the whole dependency (plus Pillow, which the repository's other icon
tools already need). No binary is committed. The standalone `oxipng` CLI is not
used and does not need to be on `PATH`.

## Running it

Audit, changing nothing — this is the default:

```sh
python3 tools/icons/optimize_icons.py
```

Recompress for real:

```sh
python3 tools/icons/optimize_icons.py --apply
```

With no arguments it walks `icons`, `modular_bluemoon`, `modular_citadel`,
`modular_sand`, `modular_splurt`, and also `code` and `config`, where a couple of
icons live beside the code that uses them. Pass directories or single files to
narrow it:

```sh
python3 tools/icons/optimize_icons.py --apply modular_bluemoon/icons/screen
```

Run it from the repository root: paths are resolved against the working
directory. Note that the audit costs the same CPU as `--apply` — the only way to
know what a file compresses to is to compress it — so both take a few minutes
over the full tree.

Useful options:

| Option | Effect |
| ------ | ------ |
| `--level N` | oxipng effort 0-6, default 6. Level 2 gets within a percent of it for a third of the time. |
| `--optimize-alpha` | Also rewrite the RGB under fully transparent pixels. Worth a fraction of a percent, and it changes what `icon.Blend(ICON_ADD)` reads there, so it is off by default. |
| `--workers N` | Process-pool size, default `min(16, cpu_count)`. Processes, not threads: pyoxipng holds the GIL for the whole call. |
| `--top N` / `--verbose` | How much of the per-file listing to print. |
| `--timeout N` | Per-file budget for oxipng's filter trials, so one pathological sheet cannot stall an unattended run. |
| `--min-saving-percent` / `--min-saving-bytes` | The replacement thresholds, below. |

A file is only replaced when it shrinks by at least 1% *and* at least 512 bytes.
Recompression is lossless, so a smaller win would still be a real one, but it is
not worth a fresh copy of the whole file in the git pack — and the threshold is
what makes a second run of the tool a no-op instead of endless churn. A file that
would grow is never replaced, whatever the thresholds are set to.

## Verifying afterwards

The repository already ships a parser that CI runs over every icon:

```sh
tools/bootstrap/python -m dmi.test
```

It loads each `.dmi`, parses its `Description` and cuts the sheet into frames, so
a damaged chunk or a resized sheet fails it. Run it after `--apply`.
