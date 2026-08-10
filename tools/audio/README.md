# Audio resource optimization

Everything DreamMaker embeds ends up in `tgstation.rsc`, which every client
downloads. `optimize_audio.py` finds the audio that costs the most there and
re-encodes it as Ogg Vorbis.

It selects a file when:

- it is not Ogg Vorbis and is at least 128 KiB — this covers `.wav`, `.mp3`,
  `.flac` and files named `.ogg` which actually contain MP3 or raw PCM;
- it is Ogg Vorbis of at least 512 KiB with a bitrate of 160 kbit/s or more.

The default command only audits:

```sh
python3 tools/audio/optimize_audio.py
```

To re-encode at the default quality 4:

```sh
python3 tools/audio/optimize_audio.py --apply
```

Speech compresses far better than music and does not need a high sample rate:

```sh
python3 tools/audio/optimize_audio.py --apply --quality 5 --max-sample-rate 24000 \
	modular_bluemoon/sound/voice/vox_sounds_alliance
```

Every output is checked for its codec, duration, channel count and size before
the original is replaced. A file that would grow, lose a channel or change
length is left alone, and so is one the re-encode shrinks by less than 10%:
some content simply does not compress further, and replacing it would spend a
lossy generation for nothing while still matching the selection thresholds on
the next run.

## Renames

A `.wav` or `.mp3` becomes a `.ogg`, so its path changes. The tool rewrites that
path literal across `.dm`, `.dme`, `.dmf`, `.dmm`, `.js`, `.ts`, `.json`, `.txt`
and `.html` sources itself.

Paths assembled at runtime (`"sound/vox/[word].ogg"`) have no literal to rewrite.
Any selected file whose path appears in no source is therefore listed and
skipped, because renaming it would break the reference silently. Check whether it
is dead or built dynamically, then re-run with `--allow-unreferenced-rename` if a
rename is safe.

Run the tool from the repository root: paths are resolved relative to the working
directory.
