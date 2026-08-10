# Audio resource optimization

Everything DreamMaker embeds ends up in `tgstation.rsc`, which every client
downloads. `optimize_audio.py` finds the audio that costs the most there and
re-encodes it as Ogg Vorbis.

It selects a file when:

- it is not Ogg Vorbis and is at least 128 KiB — this covers `.wav`, `.mp3`,
  `.flac` and files named `.ogg` which actually contain MP3 or raw PCM;
- it is Ogg Vorbis of at least 512 KiB with a bitrate of 160 kbit/s or more
  (`--min-bitrate` and `--min-bitrate-size` move both numbers);
- with `--downmix-mono`, it has more than one channel and is at least 32 KiB.

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

## Stereo which nobody hears in stereo

Half of this catalogue used to be stereo, and most of it was played through
`playsound()` with a position. BYOND mixes those into the 3D field itself, so the
second channel is downloaded and thrown away — the same rule tg writes down in
`sound/standard.md`. `--downmix-mono` selects multi-channel files and averages
them, which is both what BYOND ends up playing and what Audacity's *Mix Stereo
Down to Mono* produces.

It is only correct for audio with a source and a direction. Anything the game
sends straight to a client — `SEND_SOUND`, `playsound_local`, lobby and round-end
music, ambience, the arcade and drug tracks — really is heard in stereo, so those
directories are kept out of a downmix run with `--exclude`. The passes which
produced the current catalogue were:

```sh
# speech: mono, 24 kHz, quality 5
python3 tools/audio/optimize_audio.py --apply --downmix-mono --quality 5 --max-sample-rate 24000 \
	sound/announcer sound/voice sound/vox sound/vox_fem \
	modular_splurt/sound/voice modular_sand/sound/vox_military

# positional effects: mono, quality 4, everything heard in stereo excluded
python3 tools/audio/optimize_audio.py --apply --downmix-mono --quality 4 \
	--exclude /music/ --exclude /ambience/ --exclude /hallucinations/ --exclude /weather/ \
	--exclude /ert/ --exclude /misc/ --exclude title --exclude lobby --exclude /tetris/ \
	--exclude modular_bluemoon/sound/voice/ --exclude /halflife/ \
	--exclude /announcer/ --exclude sound/voice/ --exclude /vox

# what is left in stereo, only where the source bitrate is above what quality 4 emits
python3 tools/audio/optimize_audio.py --apply --min-bitrate 140000 --min-bitrate-size 262144 \
	sound/music sound/ambience sound/misc sound/weather sound/hallucinations \
	modular_bluemoon/sound/ambience modular_bluemoon/sound/ert \
	modular_bluemoon/sound/machines/tetris modular_bluemoon/sound/voice \
	modular_bluemoon/sound/hallucinations
```

Do not pass `-ac 1` to ffmpeg by hand instead of this flag. ffmpeg renormalizes
its downmix matrix only for integer output formats, and libvorbis takes floats,
so the shortcut makes every file about 3 dB louder than it was.

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
