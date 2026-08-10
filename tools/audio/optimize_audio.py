#!/usr/bin/env python3
"""Re-encode oversized game audio as Ogg Vorbis, rewriting resource references."""

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


DEFAULT_ROOTS = ("sound", "modular_bluemoon", "modular_citadel", "modular_sand", "modular_splurt")
AUDIO_EXTENSIONS = (".ogg", ".wav", ".mp3", ".flac", ".m4a", ".wma")
# Anything DreamMaker embeds is downloaded by every client, so the thresholds are
# deliberately low: one 512 KiB file costs more than the re-encode ever will.
MIN_TRANSCODE_SIZE = 128 * 1024
MIN_HIGH_BITRATE_SIZE = 512 * 1024
HIGH_BITRATE = 160_000
# Some content simply does not compress further at the chosen quality. Replacing
# it anyway spends a lossy generation for nothing and, because the selection
# thresholds still match it, every later run would degrade it again.
MIN_SAVING_RATIO = 0.1
# Files whose path is built at runtime ("sound/vox/[word].ogg") have no literal
# to rewrite, so renaming them would break the reference silently.
REFERENCE_SOURCE_EXTENSIONS = (".dm", ".dme", ".dmf", ".dmm", ".js", ".jsx", ".ts", ".tsx", ".json", ".txt", ".html")
REFERENCE_SCAN_IGNORED_DIRS = {".cache", "__pycache__", "data", "node_modules", "tmp"}
# ffmpeg and ffprobe both wait forever on a truncated or otherwise malformed
# file. One such file must cost that file, not the whole run: this script is
# started against thousands of them and normally left unattended.
PROBE_TIMEOUT_SECONDS = 30
ENCODE_TIMEOUT_SECONDS = 600


class NotWorthReencoding(Exception):
	"""The candidate encoded fine but is not enough smaller to be worth replacing."""


def probe(path):
	command = [
		"ffprobe",
		"-v",
		"error",
		"-select_streams",
		"a:0",
		"-show_entries",
		"stream=codec_name,sample_rate,channels:format=duration,bit_rate",
		"-of",
		"json",
		str(path),
	]
	try:
		result = subprocess.run(
			command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=PROBE_TIMEOUT_SECONDS
		)
	except subprocess.TimeoutExpired:
		print(
			"ERROR {}: ffprobe did not answer within {} seconds".format(path, PROBE_TIMEOUT_SECONDS),
			file=sys.stderr,
		)
		return None
	if result.returncode:
		return None
	payload = json.loads(result.stdout)
	if not payload.get("streams"):
		return None
	stream = payload["streams"][0]
	container = payload.get("format", {})
	return {
		"codec": stream.get("codec_name", ""),
		"sample_rate": int(stream.get("sample_rate") or 0),
		"channels": int(stream.get("channels") or 0),
		"duration": float(container.get("duration") or 0),
		"bitrate": int(container.get("bit_rate") or 0),
	}


def needs_optimization(path, metadata):
	size = path.stat().st_size
	if metadata["codec"] != "vorbis":
		return size >= MIN_TRANSCODE_SIZE
	return metadata["bitrate"] >= HIGH_BITRATE and size >= MIN_HIGH_BITRATE_SIZE


def collect_reference_sources(repository_root):
	sources = []
	for current_root, directories, filenames in os.walk(repository_root):
		directories[:] = [
			directory
			for directory in directories
			if not directory.startswith(".") and directory not in REFERENCE_SCAN_IGNORED_DIRS
		]
		for filename in filenames:
			if filename.lower().endswith(REFERENCE_SOURCE_EXTENSIONS):
				sources.append(Path(current_root) / filename)
	return sources


def rewrite_references(sources, old_relative, new_relative, apply_changes):
	"""Replace one resource path literal across the repository."""
	needle = old_relative.encode("utf-8")
	replacement = new_relative.encode("utf-8")
	touched = []
	for source in sources:
		try:
			payload = source.read_bytes()
		except OSError:
			continue
		if needle not in payload:
			continue
		touched.append(source)
		if apply_changes:
			source.write_bytes(payload.replace(needle, replacement))
	return touched


def encode(source_path, destination_path, metadata, quality, max_sample_rate):
	command = [
		"ffmpeg",
		"-v",
		"error",
		"-y",
		"-i",
		str(source_path),
		"-map_metadata",
		"0",
		"-vn",
		"-c:a",
		"libvorbis",
		"-q:a",
		str(quality),
	]
	if max_sample_rate and metadata["sample_rate"] > max_sample_rate:
		command += ["-ar", str(max_sample_rate)]
	command.append(str(destination_path))
	try:
		result = subprocess.run(
			command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=ENCODE_TIMEOUT_SECONDS
		)
	except subprocess.TimeoutExpired as error:
		# optimize() reports this as a failure of one file and removes its
		# temporary; the source is left untouched.
		raise RuntimeError("ffmpeg did not finish within {} seconds".format(ENCODE_TIMEOUT_SECONDS)) from error
	if result.returncode:
		raise RuntimeError(result.stderr.strip() or "ffmpeg failed")


def optimize(path, metadata, quality, max_sample_rate):
	"""Re-encode one file. Returns (old_size, new_size, old_path, new_path)."""
	old_size = path.stat().st_size
	final_path = path.with_suffix(".ogg")
	fd, temporary_name = tempfile.mkstemp(prefix=".{}-".format(path.stem), suffix=".ogg", dir=str(path.parent))
	os.close(fd)
	temporary_path = Path(temporary_name)
	try:
		encode(path, temporary_path, metadata, quality, max_sample_rate)
		new_metadata = probe(temporary_path)
		if not new_metadata or new_metadata["codec"] != "vorbis":
			raise RuntimeError("ffmpeg output is not Ogg Vorbis")
		allowed_duration_delta = max(0.25, metadata["duration"] * 0.002)
		if abs(new_metadata["duration"] - metadata["duration"]) > allowed_duration_delta:
			raise RuntimeError(
				"duration changed from {:.3f}s to {:.3f}s".format(metadata["duration"], new_metadata["duration"])
			)
		if new_metadata["channels"] != metadata["channels"]:
			raise RuntimeError(
				"channel count changed from {} to {}".format(metadata["channels"], new_metadata["channels"])
			)
		new_size = temporary_path.stat().st_size
		if new_size > old_size * (1 - MIN_SAVING_RATIO):
			raise NotWorthReencoding(
				"saves only {:.1f}%, below the {:.0f}% threshold".format(
					(1 - new_size / old_size) * 100, MIN_SAVING_RATIO * 100
				)
			)

		if final_path != path:
			path.unlink()
		os.replace(str(temporary_path), str(final_path))
		return old_size, new_size, path, final_path
	finally:
		try:
			temporary_path.unlink()
		except OSError:
			pass


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--apply", action="store_true", help="replace selected files; default is an audit only")
	parser.add_argument("--quality", type=float, default=4, help="libvorbis VBR quality (default: 4)")
	parser.add_argument(
		"--max-sample-rate",
		type=int,
		default=0,
		help="downsample anything above this rate; 0 keeps the source rate. Speech is fine at 24000",
	)
	parser.add_argument(
		"--allow-unreferenced-rename",
		action="store_true",
		help="also convert non-.ogg files which no source literal mentions",
	)
	parser.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 1))
	parser.add_argument("roots", nargs="*", default=list(DEFAULT_ROOTS))
	args = parser.parse_args()

	for tool in ("ffprobe", "ffmpeg"):
		if shutil.which(tool) is None:
			parser.error("{} is required".format(tool))

	repository_root = Path.cwd().resolve()
	paths = []
	for root_name in args.roots:
		root = Path(root_name)
		if root.is_file() and root.suffix.lower() in AUDIO_EXTENSIONS:
			paths.append(root)
		elif root.is_dir():
			for extension in AUDIO_EXTENSIONS:
				paths.extend(root.rglob("*{}".format(extension)))
	paths = sorted(set(path.resolve() for path in paths))

	selected = []
	with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
		futures = {executor.submit(probe, path): path for path in paths}
		for future in as_completed(futures):
			path = futures[future]
			metadata = future.result()
			if metadata and needs_optimization(path, metadata):
				selected.append((path, metadata))
	selected.sort(key=lambda item: item[0].as_posix().lower())

	old_total = sum(path.stat().st_size for path, _ in selected)
	print("Selected {} files ({:.1f} MiB)".format(len(selected), old_total / 1024 / 1024))
	for path, metadata in selected:
		print(
			"{:.2f} MiB {:>9} {:>5} Hz {:>4} kbps {}".format(
				path.stat().st_size / 1024 / 1024,
				metadata["codec"],
				metadata["sample_rate"],
				round(metadata["bitrate"] / 1000),
				path.relative_to(repository_root).as_posix(),
			)
		)

	renaming = [(path, metadata) for path, metadata in selected if path.suffix.lower() != ".ogg"]
	sources = collect_reference_sources(repository_root) if renaming else []
	unreferenced = []
	for path, _ in renaming:
		old_relative = path.relative_to(repository_root).as_posix()
		new_relative = path.with_suffix(".ogg").relative_to(repository_root).as_posix()
		if not rewrite_references(sources, old_relative, new_relative, apply_changes=False):
			unreferenced.append(old_relative)
	if unreferenced:
		print(
			"\n{} selected files would change extension, but no source literal names them. "
			"Their path is either built at runtime or they are unused:".format(len(unreferenced))
		)
		for relative_name in unreferenced:
			print("  {}".format(relative_name))
		if not args.allow_unreferenced_rename:
			print("Skipping them. Re-run with --allow-unreferenced-rename once you have checked each one.")

	if not args.apply:
		return 0

	skipped = set() if args.allow_unreferenced_rename else set(unreferenced)
	work = [
		(path, metadata)
		for path, metadata in selected
		if path.relative_to(repository_root).as_posix() not in skipped
	]

	results = []
	errors = []
	kept = 0
	with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
		futures = {
			executor.submit(optimize, path, metadata, args.quality, args.max_sample_rate): path
			for path, metadata in work
		}
		for future in as_completed(futures):
			path = futures[future]
			try:
				results.append(future.result())
			except NotWorthReencoding as reason:
				kept += 1
				print("kept {}: {}".format(path.relative_to(repository_root).as_posix(), reason))
			except Exception as error:
				errors.append((path, error))
				print("ERROR {}: {}".format(path, error), file=sys.stderr)

	rewritten = 0
	for _, _, old_path, new_path in results:
		if old_path == new_path:
			continue
		rewritten += len(
			rewrite_references(
				sources,
				old_path.relative_to(repository_root).as_posix(),
				new_path.relative_to(repository_root).as_posix(),
				apply_changes=True,
			)
		)

	new_total = sum(new_size for _, new_size, _, _ in results)
	processed_old_total = sum(old_size for old_size, _, _, _ in results)
	print(
		"Optimized {} files: {:.1f} MiB -> {:.1f} MiB (saved {:.1f} MiB), rewrote {} source references, "
		"kept {} already-compact files".format(
			len(results),
			processed_old_total / 1024 / 1024,
			new_total / 1024 / 1024,
			(processed_old_total - new_total) / 1024 / 1024,
			rewritten,
			kept,
		)
	)
	return 1 if errors else 0


if __name__ == "__main__":
	sys.exit(main())
