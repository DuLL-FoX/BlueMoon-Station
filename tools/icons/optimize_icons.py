#!/usr/bin/env python3
"""Losslessly recompress .dmi icons with oxipng, verifying the BYOND metadata survives."""

import argparse
from concurrent.futures import ProcessPoolExecutor, as_completed
import io
import os
from pathlib import Path
import struct
import sys
import tempfile
import zlib

from PIL import Image

try:
	import oxipng
except ImportError:
	# Reported by main() rather than here, so --help keeps working on a machine
	# that has not installed the encoder yet.
	oxipng = None


# "code" and "config" are here for the handful of icons which live next to the
# code that uses them instead of under icons/. Both are cheap to walk and leaving
# them out is how those files stayed unoptimized in the first place.
DEFAULT_ROOTS = ("icons", "modular_bluemoon", "modular_citadel", "modular_sand", "modular_splurt", "code", "config")
ICON_EXTENSION = ".dmi"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"
TEXT_CHUNK_TYPES = (b"tEXt", b"zTXt", b"iTXt")
# A .dmi is a PNG whose entire BYOND payload - state list, dirs, frame delays,
# loop, rewind, movement, hotspots - lives in one text chunk under this keyword.
# Lose it and the file still opens as a picture while the icon is dead.
DESCRIPTION_KEYWORD = b"Description"
# Recompression is lossless, so even a 200 byte win is real. It is still not
# worth taking: a replaced file is a whole new blob in the git pack, and a
# threshold is what makes a second run of this tool a no-op instead of churn.
MIN_SAVING_RATIO = 0.01
MIN_SAVING_BYTES = 512
# oxipng treats this as a soft budget for its filter trials and returns the best
# result found so far. One pathological sheet must not stall an unattended run.
OPTIMIZE_TIMEOUT_SECONDS = 300

STATUS_OPTIMIZED = "optimized"
STATUS_KEPT = "kept"
STATUS_REJECTED = "rejected"
STATUS_ERROR = "error"


def iter_chunks(payload):
	"""Yield (type, data) for every PNG chunk, in file order."""
	if not payload.startswith(PNG_SIGNATURE):
		raise ValueError("not a PNG")
	offset = len(PNG_SIGNATURE)
	while offset + 8 <= len(payload):
		(length,) = struct.unpack(">I", payload[offset : offset + 4])
		chunk_type = payload[offset + 4 : offset + 8]
		start = offset + 8
		end = start + length
		if end + 4 > len(payload):
			raise ValueError("chunk {} is truncated".format(chunk_type.decode("latin-1")))
		yield chunk_type, payload[start:end]
		if chunk_type == b"IEND":
			return
		offset = end + 4
	raise ValueError("no IEND chunk")


def decode_text_chunk(chunk_type, data):
	"""Return (keyword, decompressed text) for a text chunk, or None if malformed."""
	keyword, separator, remainder = data.partition(b"\x00")
	if not separator:
		return None
	if chunk_type == b"tEXt":
		return keyword, remainder
	if chunk_type == b"zTXt":
		if not remainder:
			return None
		# One compression-method byte, then the zlib stream. BYOND writes zTXt,
		# so this is the branch that carries the icon metadata in practice.
		return keyword, zlib.decompress(remainder[1:])
	# iTXt: compression flag, compression method, language tag, translated keyword.
	if len(remainder) < 2:
		return None
	compressed = remainder[0]
	rest = remainder[2:]
	_language, separator, rest = rest.partition(b"\x00")
	if not separator:
		return None
	_translated, separator, rest = rest.partition(b"\x00")
	if not separator:
		return None
	return keyword, zlib.decompress(rest) if compressed else rest


def text_chunks(payload):
	"""Map every text keyword to the list of texts stored under it, decompressed."""
	found = {}
	for chunk_type, data in iter_chunks(payload):
		if chunk_type not in TEXT_CHUNK_TYPES:
			continue
		decoded = decode_text_chunk(chunk_type, data)
		if decoded is None:
			continue
		keyword, text = decoded
		found.setdefault(keyword, []).append(text)
	return found


def keyword_list(keywords):
	return ", ".join(sorted(keyword.decode("latin-1") for keyword in keywords))


def decode_rgba(payload):
	with Image.open(io.BytesIO(payload)) as image:
		return image.convert("RGBA")


def flatten_transparent(image):
	"""Zero the RGB hidden under fully transparent pixels."""
	opaque = image.getchannel("A").point(lambda value: 255 if value else 0)
	return Image.composite(image, Image.new("RGBA", image.size), opaque)


def verify(original, candidate):
	"""Check a candidate against the original. Returns (rejection reason, flattened)."""
	try:
		original_text = text_chunks(original)
		candidate_text = text_chunks(candidate)
	except (ValueError, zlib.error) as error:
		return "chunk parse failed: {}".format(error), False

	# Checked by name first: every other difference is cosmetic next to this one.
	if original_text.get(DESCRIPTION_KEYWORD) != candidate_text.get(DESCRIPTION_KEYWORD):
		return 'the BYOND "Description" metadata did not survive byte for byte', False
	if original_text != candidate_text:
		lost = set(original_text) - set(candidate_text)
		if lost:
			return "lost text chunk(s): {}".format(keyword_list(lost)), False
		changed = [key for key in original_text if original_text[key] != candidate_text.get(key)]
		gained = set(candidate_text) - set(original_text)
		return "text chunk(s) changed: {}".format(keyword_list(changed or gained)), False

	try:
		original_image = decode_rgba(original)
		candidate_image = decode_rgba(candidate)
	except Exception as error:
		return "decode failed: {}".format(error), False
	if original_image.size != candidate_image.size:
		return "sheet size changed from {}x{} to {}x{}".format(
			original_image.size[0], original_image.size[1], candidate_image.size[0], candidate_image.size[1]
		), False
	if original_image.tobytes() == candidate_image.tobytes():
		return None, False
	# Alpha optimization and palette merging legitimately rewrite the RGB under
	# alpha=0, which no renderer can see. Anything else is a real pixel change.
	if flatten_transparent(original_image).tobytes() != flatten_transparent(candidate_image).tobytes():
		return "decoded pixels changed", False
	return None, True


def recompress(arguments):
	"""Recompress one icon in memory, verify it, and only then touch the disk."""
	path_text, level, optimize_alpha, timeout, apply_changes, min_ratio, min_bytes = arguments
	path = Path(path_text)
	record = {"path": path_text, "old_size": 0, "new_size": 0, "status": STATUS_ERROR, "reason": "", "flattened": False}
	try:
		original = path.read_bytes()
	except OSError as error:
		record["reason"] = str(error)
		return record
	record["old_size"] = record["new_size"] = len(original)

	try:
		candidate = oxipng.optimize_from_memory(
			original,
			level=level,
			# Keeping every auxiliary chunk is the whole point: --strip in any
			# form would take the Description chunk with it.
			strip=oxipng.StripChunks.none(),
			interlace=oxipng.Interlacing.Off,
			optimize_alpha=optimize_alpha,
			timeout=timeout,
		)
	except Exception as error:
		record["reason"] = str(error)
		return record

	record["new_size"] = len(candidate)
	saved = len(original) - len(candidate)
	if saved < min_bytes or saved < len(original) * min_ratio:
		record["status"] = STATUS_KEPT
		record["new_size"] = len(original)
		record["reason"] = "saves {} bytes ({:.1f}%), below the threshold".format(
			saved, saved / len(original) * 100 if original else 0
		)
		return record

	reason, flattened = verify(original, candidate)
	record["flattened"] = flattened
	if reason:
		record["status"] = STATUS_REJECTED
		record["new_size"] = len(original)
		record["reason"] = reason
		return record

	record["status"] = STATUS_OPTIMIZED
	if not apply_changes:
		return record

	# Same directory, so os.replace is an atomic rename on the same volume: an
	# interrupted run leaves either the old icon or the new one, never a stub.
	handle, temporary_name = tempfile.mkstemp(prefix=".{}-".format(path.stem), suffix=ICON_EXTENSION, dir=str(path.parent))
	try:
		with os.fdopen(handle, "wb") as stream:
			stream.write(candidate)
		os.replace(temporary_name, str(path))
	except OSError as error:
		record["status"] = STATUS_ERROR
		record["new_size"] = len(original)
		record["reason"] = str(error)
		try:
			os.unlink(temporary_name)
		except OSError:
			pass
	return record


def collect_icons(roots):
	paths = []
	for root_name in roots:
		root = Path(root_name)
		if root.is_file() and root.suffix.lower() == ICON_EXTENSION:
			paths.append(root)
		elif root.is_dir():
			paths.extend(root.rglob("*{}".format(ICON_EXTENSION)))
		else:
			print("WARNING: {} is neither a directory nor a {} file".format(root_name, ICON_EXTENSION), file=sys.stderr)
	return sorted(set(path.resolve() for path in paths))


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--apply", action="store_true", help="replace the icons; default is an audit only")
	parser.add_argument("--level", type=int, default=6, choices=range(7), help="oxipng effort, 0-6 (default: 6)")
	parser.add_argument(
		"--optimize-alpha",
		action="store_true",
		help="also rewrite the RGB under fully transparent pixels; a fraction of a percent more, "
		"but it changes what icon Blend(ICON_ADD) reads there",
	)
	parser.add_argument(
		"--timeout", type=int, default=OPTIMIZE_TIMEOUT_SECONDS, help="per-file budget for oxipng's filter trials"
	)
	parser.add_argument(
		"--min-saving-percent",
		type=float,
		default=MIN_SAVING_RATIO * 100,
		help="leave a file alone unless it shrinks by at least this much (default: {:g})".format(MIN_SAVING_RATIO * 100),
	)
	parser.add_argument(
		"--min-saving-bytes",
		type=int,
		default=MIN_SAVING_BYTES,
		help="and by at least this many bytes (default: {})".format(MIN_SAVING_BYTES),
	)
	parser.add_argument("--top", type=int, default=25, help="how many of the biggest savings to list (default: 25)")
	parser.add_argument("--verbose", action="store_true", help="list every file instead of the biggest savings")
	parser.add_argument("--workers", type=int, default=min(16, os.cpu_count() or 1))
	parser.add_argument("roots", nargs="*", default=list(DEFAULT_ROOTS))
	args = parser.parse_args()

	if oxipng is None:
		parser.error("pyoxipng is required: pip install pyoxipng")

	repository_root = Path.cwd().resolve()
	paths = collect_icons(args.roots)
	if not paths:
		print("No {} files found under {}".format(ICON_EXTENSION, ", ".join(args.roots)))
		return 0

	old_total = sum(path.stat().st_size for path in paths)
	print(
		"{} {} files ({:.1f} MiB) at oxipng level {}{}".format(
			"Optimizing" if args.apply else "Auditing",
			len(paths),
			old_total / 1024 / 1024,
			args.level,
			" with alpha optimization" if args.optimize_alpha else "",
		)
	)

	work = [
		(
			str(path),
			args.level,
			args.optimize_alpha,
			args.timeout,
			args.apply,
			args.min_saving_percent / 100,
			args.min_saving_bytes,
		)
		for path in paths
	]
	records = []
	# oxipng holds the GIL for the whole call, so a thread pool buys nothing here
	# even though the encoder itself is internally parallel; processes do.
	with ProcessPoolExecutor(max_workers=max(1, args.workers)) as executor:
		futures = [executor.submit(recompress, item) for item in work]
		for done, future in enumerate(as_completed(futures), start=1):
			records.append(future.result())
			if done % 200 == 0 or done == len(futures):
				print("  {}/{} processed".format(done, len(futures)), file=sys.stderr)

	for record in records:
		path = Path(record["path"])
		# A path handed in from outside the repository has no relative form; show it whole.
		record["relative"] = (
			path.relative_to(repository_root).as_posix() if path.is_relative_to(repository_root) else path.as_posix()
		)
	records.sort(key=lambda record: record["relative"].lower())

	optimized = [record for record in records if record["status"] == STATUS_OPTIMIZED]
	kept = [record for record in records if record["status"] == STATUS_KEPT]
	rejected = [record for record in records if record["status"] == STATUS_REJECTED]
	errors = [record for record in records if record["status"] == STATUS_ERROR]

	listed = optimized if args.verbose else sorted(
		optimized, key=lambda record: record["old_size"] - record["new_size"], reverse=True
	)[: max(0, args.top)]
	if listed:
		print("\n{}:".format("All savings" if args.verbose else "Biggest savings"))
		for record in listed:
			saved = record["old_size"] - record["new_size"]
			print(
				"  {:>8.1f} KiB -> {:>8.1f} KiB  -{:4.1f}%  {}".format(
					record["old_size"] / 1024,
					record["new_size"] / 1024,
					saved / record["old_size"] * 100,
					record["relative"],
				)
			)

	for record in rejected:
		print("REJECTED {}: {}".format(record["relative"], record["reason"]), file=sys.stderr)
	for record in errors:
		print("ERROR {}: {}".format(record["relative"], record["reason"]), file=sys.stderr)

	flattened = sum(1 for record in optimized if record["flattened"])
	new_total = sum(record["new_size"] for record in records)
	print(
		"\n{} {} of {} files: {:.1f} MiB -> {:.1f} MiB (saved {:.1f} MiB, {:.1f}%)".format(
			"Optimized" if args.apply else "Would optimize",
			len(optimized),
			len(records),
			old_total / 1024 / 1024,
			new_total / 1024 / 1024,
			(old_total - new_total) / 1024 / 1024,
			(old_total - new_total) / old_total * 100 if old_total else 0,
		)
	)
	print(
		"{} already compact, {} rejected by the metadata/pixel check, {} failed to read or encode, "
		"{} matched only after flattening transparent pixels".format(len(kept), len(rejected), len(errors), flattened)
	)
	if not args.apply and optimized:
		print("Audit only. Re-run with --apply to install these.")
	return 1 if errors or rejected else 0


if __name__ == "__main__":
	sys.exit(main())
