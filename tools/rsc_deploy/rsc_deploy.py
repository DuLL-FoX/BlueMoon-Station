#!/usr/bin/env python3
"""Prepare and atomically publish a content-addressed BYOND resource archive for TGS."""

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
import zipfile


MANIFEST_NAME = ".rsc-deploy.json"
GENERATED_DEFINES_NAME = ".rsc-deployment.dm"
BROWSER_ASSET_SPEC_NAME = "browser_assets.json"
RELEASE_MANIFEST_SCHEMA_VERSION = 1
RELEASES_SUBDIR = ".releases"
DME_NAME = "tgstation.dme"
SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]+$")
ASSET_CONFIG_BEGIN = "# BEGIN MANAGED EXTERNAL BROWSER ASSETS"
ASSET_CONFIG_END = "# END MANAGED EXTERNAL BROWSER ASSETS"
LOBBY_IMAGE_EXTENSIONS = {".gif", ".jpeg", ".jpg", ".png", ".webp"}
LOBBY_AUDIO_EXTENSIONS = {".flac", ".mp3", ".ogg", ".wav"}
RESOURCE_REFERENCE_SOURCE_EXTENSIONS = {".dm", ".dme", ".dmf", ".dmm"}
SINGLE_QUOTE = re.compile(rb"'")
# Everything which can add or remove a resource from the compiled RSC without
# touching a resource file: conditional compilation, and the include graph.
BUILD_CONFIGURATION_DIRECTIVE = re.compile(
	rb"^\s*#\s*(?:define|undef|include|if|ifdef|ifndef|elif|else|endif)\b", re.IGNORECASE
)
# TGS picks the compiler from .tgs.yml, and another DreamMaker may lay out the
# resource container differently, so that one field belongs in the fingerprint.
# Nothing else in the file does: the hook script names, the static file list and
# the security level orchestrate the deployment without changing a single byte
# DreamMaker embeds. Hashing the whole file made every edit to a TGS hook
# mapping invalidate the archive name and force every client to redownload it.
TGS_CONFIG_NAME = ".tgs.yml"
TGS_BYOND_VERSION = re.compile(r"^[ \t]*byond[ \t]*:[ \t]*[\"']?([^\"'#\s]+)", re.MULTILINE)
GIT_TIMEOUT_SECONDS = 60
# nginx is commonly reloaded around a deployment, so one refused connection is
# not evidence that the archive is unreachable.
VERIFY_RETRY_DELAYS = (1, 3)
ARCHIVE_WRITE_RETRY_DELAY = 3
FINGERPRINT_CACHE_NAME = ".rsc-input-cache.json"
FINGERPRINT_CACHE_VERSION = 2
# Only top-level repository directories are skipped. These names also occur deep
# inside the game tree ("code/game/objects/items/tools", "…/simple_animal/bot"),
# and pruning them at every level would hide the resources referenced there from
# the fingerprint.
RESOURCE_SCAN_IGNORED_TOP_LEVEL_DIRS = {
	"bot",
	"config",
	"data",
	"node_modules",
	"SQL",
	"tgstation-server",
	"tmp",
	"tools",
}


class DeployError(RuntimeError):
	pass


def log(message):
	print("[rsc-deploy] {}".format(message), flush=True)


def make_readable(path, mode):
	"""Apply a mode nginx can serve regardless of the hook process umask.

	mkstemp creates 0600 files and mkdir honours the umask, so without this an
	otherwise successful deployment publishes files and directories the web
	server cannot read.
	"""
	try:
		os.chmod(str(path), mode)
	except OSError as error:
		log("warning: could not set the mode of {}: {}".format(path, error))


def ensure_public_directory(path):
	path = Path(path)
	missing = []
	probe = path
	while not probe.is_dir():
		missing.append(probe)
		if probe.parent == probe:
			break
		probe = probe.parent
	path.mkdir(parents=True, exist_ok=True)
	for created in missing:
		make_readable(created, 0o755)
	return path


def atomic_write(path, content):
	path = Path(path)
	ensure_public_directory(path.parent)
	# An existing file keeps whatever the operator or TGS gave it; a new one gets
	# a world-readable mode rather than mkstemp's 0600.
	try:
		mode = path.stat().st_mode & 0o777
	except OSError:
		mode = 0o644
	fd, temporary_name = tempfile.mkstemp(prefix=".{}-".format(path.name), dir=str(path.parent))
	try:
		with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as output:
			output.write(content)
			output.flush()
			os.fsync(output.fileno())
		make_readable(temporary_name, mode)
		os.replace(temporary_name, str(path))
	except Exception:
		try:
			os.unlink(temporary_name)
		except OSError:
			pass
		raise


def atomic_copy(source, destination):
	source = Path(source)
	destination = Path(destination)
	ensure_public_directory(destination.parent)
	if destination.is_file() and destination.stat().st_size == source.stat().st_size:
		# Content-addressed, so the payload is already correct; only repair a
		# mode left behind by an earlier run under a stricter umask.
		if destination.stat().st_mode & 0o044 != 0o044:
			make_readable(destination, 0o644)
		return
	fd, temporary_name = tempfile.mkstemp(prefix=".{}-".format(destination.name), dir=str(destination.parent))
	try:
		with source.open("rb") as input_file, os.fdopen(fd, "wb") as output_file:
			shutil.copyfileobj(input_file, output_file, length=1024 * 1024)
			output_file.flush()
			os.fsync(output_file.fileno())
		make_readable(temporary_name, 0o644)
		os.replace(temporary_name, str(destination))
	except Exception:
		try:
			os.unlink(temporary_name)
		except OSError:
			pass
		raise


def parse_bool(value, setting_name):
	normalized = str(value).strip().lower()
	if normalized in ("1", "true", "yes", "on"):
		return True
	if normalized in ("0", "false", "no", "off"):
		return False
	raise DeployError("{} must be 0/1, true/false, yes/no or on/off".format(setting_name))


def load_settings(game_dir, configured_path=None):
	config_path = Path(configured_path) if configured_path else Path(game_dir) / "config" / "rsc_deploy.env"
	config_path = config_path.resolve()
	if not config_path.is_file():
		log("{} is absent; external RSC publishing is disabled".format(config_path))
		return None

	settings = {}
	for line_number, raw_line in enumerate(config_path.read_text(encoding="utf-8-sig").splitlines(), 1):
		line = raw_line.strip()
		if not line or line.startswith("#"):
			continue
		if line.startswith("export "):
			line = line[7:].lstrip()
		if "=" not in line:
			raise DeployError("{}:{} must be KEY=VALUE".format(config_path, line_number))
		key, value = line.split("=", 1)
		key = key.strip()
		value = value.strip()
		if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
			value = value[1:-1]
		settings[key] = value

	for required in ("RSC_PUBLIC_BASE_URL", "RSC_PUBLISH_DIR"):
		if not settings.get(required):
			raise DeployError("{} is required in {}".format(required, config_path))

	# Checked here rather than in publish() so a typo costs a log line instead of
	# a full DreamMaker compilation.
	if not Path(settings["RSC_PUBLISH_DIR"]).expanduser().is_absolute():
		raise DeployError("RSC_PUBLISH_DIR must be an absolute path")

	base_url = settings["RSC_PUBLIC_BASE_URL"].rstrip("/")
	if not base_url.startswith(("http://", "https://")):
		raise DeployError("RSC_PUBLIC_BASE_URL must start with http:// or https://")
	settings["RSC_PUBLIC_BASE_URL"] = base_url
	public_base_urls = [base_url]
	configured_mirrors = settings.get("RSC_PUBLIC_MIRROR_BASE_URLS", "").strip()
	if configured_mirrors:
		for mirror_number, configured_mirror in enumerate(configured_mirrors.split(";"), 1):
			mirror_url = configured_mirror.strip().rstrip("/")
			if not mirror_url:
				continue
			if not mirror_url.startswith(("http://", "https://")):
				raise DeployError(
					"RSC_PUBLIC_MIRROR_BASE_URLS entry {} must start with http:// or https://".format(
						mirror_number
					)
				)
			if mirror_url not in public_base_urls:
				public_base_urls.append(mirror_url)
	settings["RSC_PUBLIC_BASE_URLS"] = public_base_urls

	prefix = settings.get("RSC_ARCHIVE_PREFIX", "Moon-Blue")
	if not SAFE_NAME.fullmatch(prefix):
		raise DeployError("RSC_ARCHIVE_PREFIX may only contain letters, digits, dot, dash and underscore")
	settings["RSC_ARCHIVE_PREFIX"] = prefix
	deployment_namespace = settings.get("RSC_DEPLOYMENT_NAMESPACE", "").strip()
	if deployment_namespace and not SAFE_NAME.fullmatch(deployment_namespace):
		raise DeployError("RSC_DEPLOYMENT_NAMESPACE may only contain letters, digits, dot, dash and underscore")
	settings["RSC_DEPLOYMENT_NAMESPACE"] = deployment_namespace
	settings["_CONFIG_PATH"] = config_path

	# Unmanaged builds fall back to the unversioned EXTERNAL_RSC_URLS name from
	# config/entries/resources.txt, which nothing else publishes any more.
	legacy_alias = settings.get("RSC_LEGACY_ALIAS_NAME", "{}.zip".format(prefix)).strip()
	if legacy_alias:
		if not SAFE_NAME.fullmatch(legacy_alias) or not legacy_alias.lower().endswith(".zip"):
			raise DeployError("RSC_LEGACY_ALIAS_NAME must be one safe .zip file name")
		if legacy_alias.startswith("{}-".format(prefix)):
			raise DeployError("RSC_LEGACY_ALIAS_NAME must not collide with managed archive names")
	settings["RSC_LEGACY_ALIAS_NAME"] = legacy_alias

	for setting_name, default in (
		("RSC_LOBBY_MEDIA_SUBDIR", "lobby-media"),
		("RSC_ASSET_WEBROOT_SUBDIR", "browser-assets"),
	):
		value = settings.get(setting_name, default).strip("/\\")
		if not SAFE_NAME.fullmatch(value):
			raise DeployError("{} must be one safe directory name".format(setting_name))
		settings[setting_name] = value
	settings["RSC_VERIFY_PUBLIC_URL"] = parse_bool(settings.get("RSC_VERIFY_PUBLIC_URL", "1"), "RSC_VERIFY_PUBLIC_URL")
	settings["RSC_REQUIRE_PUBLIC_VERIFICATION"] = parse_bool(
		settings.get("RSC_REQUIRE_PUBLIC_VERIFICATION", "0"), "RSC_REQUIRE_PUBLIC_VERIFICATION"
	)
	settings["RSC_PUBLISH_LOBBY_MEDIA"] = parse_bool(settings.get("RSC_PUBLISH_LOBBY_MEDIA", "1"), "RSC_PUBLISH_LOBBY_MEDIA")
	settings["RSC_ENABLE_ASSET_WEBROOT"] = parse_bool(settings.get("RSC_ENABLE_ASSET_WEBROOT", "1"), "RSC_ENABLE_ASSET_WEBROOT")
	settings["RSC_PRUNE_ENABLED"] = parse_bool(settings.get("RSC_PRUNE_ENABLED", "1"), "RSC_PRUNE_ENABLED")
	if settings["RSC_REQUIRE_PUBLIC_VERIFICATION"] and not settings["RSC_VERIFY_PUBLIC_URL"]:
		raise DeployError("RSC_REQUIRE_PUBLIC_VERIFICATION requires RSC_VERIFY_PUBLIC_URL=1")

	try:
		settings["RSC_COMPRESSION_LEVEL"] = int(settings.get("RSC_COMPRESSION_LEVEL", "6"))
		settings["RSC_MIN_FREE_BYTES"] = int(settings.get("RSC_MIN_FREE_BYTES", str(512 * 1024 * 1024)))
		settings["RSC_KEEP_UNREFERENCED"] = int(settings.get("RSC_KEEP_UNREFERENCED", "2"))
		settings["RSC_PRUNE_GRACE_HOURS"] = int(settings.get("RSC_PRUNE_GRACE_HOURS", "24"))
	except ValueError as error:
		raise DeployError(
			"RSC_COMPRESSION_LEVEL, RSC_MIN_FREE_BYTES, RSC_KEEP_UNREFERENCED and "
			"RSC_PRUNE_GRACE_HOURS must be integers"
		) from error
	if not 0 <= settings["RSC_COMPRESSION_LEVEL"] <= 9:
		raise DeployError("RSC_COMPRESSION_LEVEL must be between 0 and 9")
	if settings["RSC_MIN_FREE_BYTES"] < 0:
		raise DeployError("RSC_MIN_FREE_BYTES must not be negative")
	if settings["RSC_KEEP_UNREFERENCED"] < 0:
		raise DeployError("RSC_KEEP_UNREFERENCED must not be negative")
	if settings["RSC_PRUNE_GRACE_HOURS"] < 0:
		raise DeployError("RSC_PRUNE_GRACE_HOURS must not be negative")

	configured_roots = settings.get("RSC_DEPLOYMENT_ROOTS", "").strip()
	if configured_roots:
		deployment_roots = []
		for configured_root in configured_roots.split(";"):
			configured_root = configured_root.strip()
			if not configured_root:
				continue
			root = Path(configured_root).expanduser()
			if not root.is_absolute():
				raise DeployError("every RSC_DEPLOYMENT_ROOTS entry must be an absolute path")
			deployment_roots.append(root.resolve())
		if not deployment_roots:
			raise DeployError("RSC_DEPLOYMENT_ROOTS does not contain any paths")
		settings["RSC_DEPLOYMENT_ROOTS"] = deployment_roots
	else:
		settings["RSC_DEPLOYMENT_ROOTS"] = None
	return settings


def git_revision(game_dir, supplied_revision):
	try:
		result = subprocess.run(
			["git", "-C", str(game_dir), "rev-parse", "HEAD"],
			check=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.DEVNULL,
			text=True,
			timeout=GIT_TIMEOUT_SECONDS,
		)
		revision = result.stdout.strip()
	except subprocess.TimeoutExpired:
		# The revision only labels the deployment, so a hung git is not worth failing a
		# build over: TGS already supplied one. _git_file_identities stays fatal, because
		# there a hung git silently shrinks the fingerprint instead of a log line.
		log(
			"warning: git rev-parse did not finish within {} seconds in {}; using the revision "
			"supplied by TGS instead".format(GIT_TIMEOUT_SECONDS, game_dir)
		)
		revision = supplied_revision.strip()
	except (OSError, subprocess.CalledProcessError):
		revision = supplied_revision.strip()
	if not revision:
		revision = "unknown"
	revision = re.sub(r"[^A-Za-z0-9._-]", "-", revision)
	return revision[:12]


def dm_string(value):
	# "[" opens string interpolation in DM, so it has to be escaped alongside the
	# backslash and the quote or a URL turns into a compile error.
	return '"{}"'.format(value.replace("\\", "\\\\").replace('"', '\\"').replace("[", "\\["))


def dm_list(values):
	return "list({})".format(", ".join(dm_string(value) for value in values))


def deployment_release_id(settings, revision, archive_input_hash):
	"""Identify the whole deployable DMB, not only its reusable RSC payload."""
	return "{}-{}-{}".format(archive_name_prefix(settings), revision, archive_input_hash[:16])


def ensure_generated_defines_include(game_dir):
	"""Include the generated defines from this disposable TGS deployment only.

	Keeping the include out of tracked DM source lets a clean checkout compile
	with ``-DTGS`` even when no deployment hook has run. The current PreCompile
	hook calls this before DreamMaker; an instance carrying an older hook simply
	keeps the unmanaged EXTERNAL_RSC_URLS fallback instead of failing its build.
	"""
	dme_path = Path(game_dir) / DME_NAME
	try:
		text = dme_path.read_text(encoding="utf-8-sig")
	except (OSError, UnicodeDecodeError) as error:
		raise DeployError("cannot read deployment DME {}: {}".format(dme_path, error)) from error
	include_line = '#include "{}"'.format(GENERATED_DEFINES_NAME)
	if any(line.strip() == include_line for line in text.splitlines()):
		return
	atomic_write(dme_path, "{}\n{}".format(include_line, text))


def deployment_namespace(settings):
	namespace = settings["RSC_DEPLOYMENT_NAMESPACE"]
	if not namespace:
		# Separate TGS instances normally have distinct persistent config paths.
		# Hash rather than expose the host path in a public archive name.
		namespace = os.path.normcase(str(Path(settings["_CONFIG_PATH"]).resolve()))
	return namespace


def deployment_namespace_tag(settings):
	"""Return the short archive-name segment which identifies this instance.

	Cleanup can only tell its own archives from another instance's by name, so
	the namespace has to be visible in the name and not merely folded into the
	content hash.
	"""
	digest = hashlib.sha256()
	_hash_record(digest, "version", "rsc-namespace-tag-v1")
	_hash_record(digest, "deployment-namespace", deployment_namespace(settings))
	return digest.hexdigest()[:8]


def archive_name_prefix(settings):
	return "{}-{}".format(settings["RSC_ARCHIVE_PREFIX"], deployment_namespace_tag(settings))


def archive_inputs_sha256(resource_input_hash, settings):
	"""Refine a resource fingerprint with a stable per-instance namespace."""
	digest = hashlib.sha256()
	_hash_record(digest, "version", "rsc-archive-inputs-v1")
	_hash_record(digest, "resources-and-build", resource_input_hash)
	_hash_record(digest, "deployment-namespace", deployment_namespace(settings))
	return digest.hexdigest()


def _hash_record(digest, record_type, name, payload=None):
	digest.update(record_type.encode("ascii"))
	digest.update(b"\0")
	digest.update(name.encode("utf-8", errors="surrogateescape"))
	digest.update(b"\0")
	if payload is not None:
		digest.update(str(len(payload)).encode("ascii"))
		digest.update(b"\0")
		digest.update(payload)
	digest.update(b"\0")


def _git_file_identities(game_dir):
	"""Return clean index blob IDs without reading every tracked file."""
	try:
		index_result = subprocess.run(
			["git", "-C", str(game_dir), "ls-files", "--stage", "-z"],
			check=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.DEVNULL,
			timeout=GIT_TIMEOUT_SECONDS,
		)
		dirty_result = subprocess.run(
			["git", "-C", str(game_dir), "status", "--porcelain=v1", "-z", "--untracked-files=no"],
			check=True,
			stdout=subprocess.PIPE,
			stderr=subprocess.DEVNULL,
			timeout=GIT_TIMEOUT_SECONDS,
		)
	except subprocess.TimeoutExpired as error:
		# Falling back to a full rescan would hide a repository which stopped
		# answering, and every later deployment would pay for it silently.
		raise DeployError(
			"git did not finish within {} seconds in {}".format(GIT_TIMEOUT_SECONDS, game_dir)
		) from error
	except (OSError, subprocess.CalledProcessError):
		return {}, set()

	identities = {}
	for record in index_result.stdout.split(b"\0"):
		if not record or b"\t" not in record:
			continue
		metadata, raw_name = record.split(b"\t", 1)
		parts = metadata.split()
		if len(parts) != 3 or parts[2] != b"0":
			continue
		name = raw_name.decode("utf-8", errors="surrogateescape").replace("\\", "/")
		identities[name] = "git:{}".format(parts[1].decode("ascii"))

	dirty = set()
	records = dirty_result.stdout.split(b"\0")
	index = 0
	while index < len(records):
		record = records[index]
		index += 1
		if len(record) < 4:
			continue
		status = record[:2]
		name = record[3:].decode("utf-8", errors="surrogateescape").replace("\\", "/")
		dirty.add(name)
		# Rename/copy porcelain records carry the second path as another NUL item.
		if b"R" in status or b"C" in status:
			if index < len(records):
				dirty.add(records[index].decode("utf-8", errors="surrogateescape").replace("\\", "/"))
				index += 1
	return identities, dirty


def _load_fingerprint_cache(cache_path):
	if not cache_path:
		return {"sources": {}, "files": {}}
	try:
		payload = json.loads(Path(cache_path).read_text(encoding="utf-8"))
		if payload.get("version") != FINGERPRINT_CACHE_VERSION:
			# Cached scans store whatever the parser extracted at the time, so a
			# parser change has to discard them instead of reusing stale records.
			return {"sources": {}, "files": {}}
		return {
			"sources": payload.get("sources", {}),
			"files": payload.get("files", {}),
		}
	except (OSError, ValueError, json.JSONDecodeError):
		return {"sources": {}, "files": {}}


def _resource_literals(payload):
	"""Return every span which a DM resource literal could occupy.

	A left-to-right scan for disjoint 'x' pairs loses a real literal whenever an
	apostrophe appears earlier on the same line ("Explorer's Webbing" swallows
	the following 'icons/obj/storage.dmi'). Every adjacent quote pair is offered
	instead; candidates which do not name an existing file are discarded by the
	caller, so an extra guess costs nothing while a missed one silently freezes
	the published archive.
	"""
	literals = []
	positions = [match.start() for match in SINGLE_QUOTE.finditer(payload)]
	for opening, closing in zip(positions, positions[1:]):
		candidate = payload[opening + 1:closing]
		if not candidate or b"\r" in candidate or b"\n" in candidate:
			continue
		literals.append(candidate)
	return literals


def _scan_resource_source(path):
	try:
		payload = Path(path).read_bytes()
	except OSError as error:
		raise DeployError("could not read resource-reference source {}: {}".format(path, error)) from error
	references = [
		candidate.decode("utf-8", errors="surrogateescape").replace("\\", "/")
		for candidate in _resource_literals(payload)
	]
	directives = []
	lines = payload.splitlines(keepends=True)
	line_number = 0
	while line_number < len(lines):
		line = lines[line_number]
		line_number += 1
		if not BUILD_CONFIGURATION_DIRECTIVE.match(line):
			continue
		directive = bytearray(line)
		while directive.rstrip(b"\r\n").endswith(b"\\") and line_number < len(lines):
			directive.extend(lines[line_number])
			line_number += 1
		directives.append(bytes(directive).decode("utf-8", errors="replace"))
	return references, directives


def compiler_build_inputs(game_dir):
	"""Return build inputs which change the compiled RSC without being resources.

	Only the compiler identity qualifies today. Deployment tooling - the TGS hook
	scripts, this script itself - must stay out: it decides how an archive is
	published, never what DreamMaker embeds, and putting it in the fingerprint
	would make routine hook maintenance evict every client's cached archive.
	"""
	inputs = []
	tgs_config = Path(game_dir) / TGS_CONFIG_NAME
	try:
		payload = tgs_config.read_text(encoding="utf-8-sig")
	except FileNotFoundError:
		# No TGS config at all is the normal shape of a local checkout: there is no
		# compiler version to pin and nothing to warn about.
		return inputs
	except (OSError, UnicodeDecodeError) as error:
		log(
			"warning: could not read {}: {}; the compiler version stays out of the RSC "
			"fingerprint, so a BYOND upgrade will not move the archive name and "
			"validate_archive will keep rejecting the mismatch".format(tgs_config, error)
		)
		return inputs
	match = TGS_BYOND_VERSION.search(payload)
	if not match:
		log(
			"warning: no 'byond:' version found in {}; the compiler version stays out of the "
			"RSC fingerprint, so a BYOND upgrade will not move the archive name and "
			"validate_archive will keep rejecting the mismatch".format(tgs_config)
		)
		return inputs
	inputs.append(("byond-version", match.group(1)))
	return inputs


def resource_inputs_sha256(game_dir, cache_path=None):
	"""Hash statically referenced resource files deterministically.

	The source scan catches code changes which add or remove an already-existing
	resource. Unreferenced media is deliberately excluded: browser bundles and
	other repository assets which DreamMaker does not embed must not invalidate
	the entire RSC cache. Preprocessor directives are included so two build
	variants cannot accidentally select the same archive: conditional
	compilation and the include graph both decide which referenced resources
	DreamMaker actually embeds, and an archive whose name did not move while its
	contents did is rejected at publish time rather than served. A persistent
	per-instance cache avoids reparsing unchanged maps and rehashing unchanged
	resources on every TGS deployment.
	"""
	game_dir = Path(game_dir)
	resource_files = {}
	references = set()
	build_directives = []
	git_identities, dirty_files = _git_file_identities(game_dir)
	cache = _load_fingerprint_cache(cache_path)
	used_source_cache = {}
	used_file_cache = {}

	for current_root, directories, filenames in os.walk(game_dir):
		current_root = Path(current_root)
		at_repository_root = current_root == game_dir
		directories[:] = sorted(
			directory
			for directory in directories
			# Dot directories hold caches, VCS metadata and, on developer
			# machines, whole additional checkouts; none of them compile.
			if not directory.startswith(".")
			and not (at_repository_root and directory in RESOURCE_SCAN_IGNORED_TOP_LEVEL_DIRS)
		)
		for filename in sorted(filenames):
			path = current_root / filename
			try:
				relative_path = path.relative_to(game_dir)
			except ValueError:
				continue
			relative_name = relative_path.as_posix()
			if relative_name in (MANIFEST_NAME, GENERATED_DEFINES_NAME):
				continue
			suffix = path.suffix.lower()
			if suffix not in RESOURCE_REFERENCE_SOURCE_EXTENSIONS:
				continue
			identity = git_identities.get(relative_name) if relative_name not in dirty_files else None
			cached_source = cache["sources"].get(identity) if identity else None
			if isinstance(cached_source, dict):
				literals = cached_source.get("references", [])
				directives = cached_source.get("directives", [])
			else:
				literals, directives = _scan_resource_source(path)
			if identity:
				used_source_cache[identity] = {"references": literals, "directives": directives}
			for literal in literals:
				while literal.startswith("./"):
					literal = literal[2:]
				literal_path = Path(literal)
				if literal_path.is_absolute() or ".." in literal_path.parts:
					continue
				referenced_path = game_dir / literal_path
				if referenced_path.is_file():
					references.add(literal)
					resource_files[literal_path.as_posix()] = referenced_path
			for directive_number, directive in enumerate(directives):
				build_directives.append((relative_name, directive_number, directive))

	digest = hashlib.sha256()
	_hash_record(digest, "version", "rsc-resource-inputs-v5")
	for name, value in compiler_build_inputs(game_dir):
		_hash_record(digest, "build-input", name, value.encode("utf-8"))
	for literal in sorted(references):
		_hash_record(digest, "reference", literal)
	for relative_name, directive_number, directive in sorted(build_directives):
		_hash_record(
			digest,
			"build-directive",
			"{}:{}".format(relative_name, directive_number),
			directive.encode("utf-8"),
		)
	for relative_name in sorted(resource_files):
		path = resource_files[relative_name]
		try:
			identity = git_identities.get(relative_name) if relative_name not in dirty_files else None
			file_hash = cache["files"].get(identity) if identity else None
			if not isinstance(file_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", file_hash):
				file_hash = sha256_file(path)
			if identity:
				used_file_cache[identity] = file_hash
			_hash_record(digest, "file-sha256", relative_name, file_hash.encode("ascii"))
		except OSError as error:
			raise DeployError("could not read resource input {}: {}".format(path, error)) from error
	if cache_path:
		try:
			atomic_write(
				cache_path,
				json.dumps(
					{"version": FINGERPRINT_CACHE_VERSION, "sources": used_source_cache, "files": used_file_cache},
					ensure_ascii=True,
					sort_keys=True,
				) + "\n",
			)
		except OSError as error:
			log("warning: could not update resource fingerprint cache {}: {}".format(cache_path, error))
	return digest.hexdigest()


def preflight_publish_target(settings):
	"""Reject a publish target which cannot work, before DreamMaker is started.

	publish performs the same write probe and free-space check, but it only runs
	after a 15-25 minute compilation. A directory nobody can write to, a full
	filesystem and a missing resources.txt are all knowable up front, so they are
	worth one second here instead of a failed deployment at the end.
	"""
	publish_dir = Path(settings["RSC_PUBLISH_DIR"]).expanduser()
	try:
		free_bytes = validate_writable_directory(publish_dir, settings["RSC_MIN_FREE_BYTES"])
	except OSError as error:
		raise DeployError("cannot prepare the publish directory {}: {}".format(publish_dir, error)) from error
	require_asset_config(settings)
	log("publish directory {} is writable ({} free bytes)".format(publish_dir, free_bytes))
	if settings["RSC_VERIFY_PUBLIC_URL"]:
		# One shot, no backoff. This probe is advisory and runs before a 15-25 minute
		# compilation: retrying an unreachable host here would add half a minute of
		# waiting to every build behind a firewall, and the archive URL is verified for
		# real by verify_public_url() once the file exists.
		probe_public_base_url("{}/".format(settings["RSC_PUBLIC_BASE_URL"]), retry_delays=())


def prepare(args):
	game_dir = Path(args.game_dir).resolve()
	settings = load_settings(game_dir, args.config)
	if settings is None:
		# A previous attempt in the same disposable directory may already have
		# inserted the include. Keep that retry safe while unmanaged clean builds
		# rely on the fallbacks in _compile_options.dm and need no generated file.
		atomic_write(game_dir / GENERATED_DEFINES_NAME, "// External RSC publishing is disabled.\n")
		return

	preflight_publish_target(settings)
	# Never leave a generated include pointing at a missing file, even if the
	# fingerprinting step below fails and TGS reports the hook error.
	atomic_write(game_dir / GENERATED_DEFINES_NAME, "// External RSC publishing is disabled.\n")
	ensure_generated_defines_include(game_dir)
	revision = git_revision(game_dir, args.revision or "")
	stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
	cache_path = settings["_CONFIG_PATH"].parent / FINGERPRINT_CACHE_NAME
	input_hash = resource_inputs_sha256(game_dir, cache_path=cache_path)
	archive_input_hash = archive_inputs_sha256(input_hash, settings)
	archive_name = "{}-{}.zip".format(archive_name_prefix(settings), archive_input_hash)
	public_urls = ["{}/{}".format(base_url, archive_name) for base_url in settings["RSC_PUBLIC_BASE_URLS"]]
	public_url = public_urls[0]
	release_id = deployment_release_id(settings, revision, archive_input_hash)
	asset_manifest_name = None
	if settings["RSC_ENABLE_ASSET_WEBROOT"]:
		asset_manifest_name = "{}.txt".format(release_id)

	generated_defines = "// Generated by tools/rsc_deploy; do not commit.\n"
	generated_defines += "#ifdef DEPLOYMENT_RSC_URLS\n#undef DEPLOYMENT_RSC_URLS\n#endif\n"
	generated_defines += "#define DEPLOYMENT_RSC_URLS {}\n".format(dm_list(public_urls))
	generated_defines += "#ifdef DEPLOYMENT_ASSET_MANIFEST_NAME\n#undef DEPLOYMENT_ASSET_MANIFEST_NAME\n#endif\n"
	generated_defines += "#define DEPLOYMENT_ASSET_MANIFEST_NAME {}\n".format(
		dm_string(asset_manifest_name) if asset_manifest_name else "null"
	)
	generated_defines += "#ifdef DEPLOYMENT_RELEASE_ID\n#undef DEPLOYMENT_RELEASE_ID\n#endif\n"
	generated_defines += "#define DEPLOYMENT_RELEASE_ID {}\n".format(dm_string(release_id))
	atomic_write(game_dir / GENERATED_DEFINES_NAME, generated_defines)

	manifest = {
		"schema_version": RELEASE_MANIFEST_SCHEMA_VERSION,
		"release_id": release_id,
		"archive_name": archive_name,
		"public_url": public_url,
		"public_urls": public_urls,
		"revision": revision,
		"resource_inputs_sha256": input_hash,
		"archive_inputs_sha256": archive_input_hash,
		"browser_asset_manifest": asset_manifest_name,
		"browser_asset_webroot_enabled": settings["RSC_ENABLE_ASSET_WEBROOT"],
		"lobby_media_enabled": settings["RSC_PUBLISH_LOBBY_MEDIA"],
		"created_utc": stamp,
	}
	atomic_write(game_dir / MANIFEST_NAME, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
	log("prepared {} RSC URL(s) for this compilation: {}".format(len(public_urls), ", ".join(public_urls)))


def sha256_file(path):
	digest = hashlib.sha256()
	with Path(path).open("rb") as source:
		for chunk in iter(lambda: source.read(1024 * 1024), b""):
			digest.update(chunk)
	return digest.hexdigest()


def md5_file(path):
	digest = hashlib.md5()
	with Path(path).open("rb") as source:
		for chunk in iter(lambda: source.read(1024 * 1024), b""):
			digest.update(chunk)
	return digest.hexdigest()


def _validate_browser_asset_name(value, context):
	if not isinstance(value, str) or Path(value).name != value or not SAFE_NAME.fullmatch(value):
		raise DeployError("{} has an unsafe browser asset name: {}".format(context, value))
	return value


def plan_static_browser_assets(game_dir, spec_path=None):
	"""Reproduce the DM webroot layout for browser files known at build time.

	Runtime-generated spritesheets deliberately are not part of this plan. The
	composite transport can serve those through browse_rsc without mutating the
	public content store.
	"""
	game_dir = Path(game_dir).resolve()
	if spec_path:
		spec_path = Path(spec_path)
	else:
		spec_path = game_dir / "tools" / "rsc_deploy" / BROWSER_ASSET_SPEC_NAME
		if not spec_path.is_file():
			# Integration tests exercise a disposable Game directory while importing
			# the deploy tool from the checkout which owns the specification.
			spec_path = Path(__file__).with_name(BROWSER_ASSET_SPEC_NAME)
	if not spec_path.is_file():
		raise DeployError("static browser asset specification is missing: {}".format(spec_path))
	try:
		spec = json.loads(spec_path.read_text(encoding="utf-8"))
	except (OSError, json.JSONDecodeError) as error:
		raise DeployError("cannot read static browser asset specification {}: {}".format(spec_path, error)) from error
	if spec.get("version") != 1 or not isinstance(spec.get("simple"), dict) or not isinstance(spec.get("namespaced"), dict):
		raise DeployError("{} must contain version 1 simple and namespaced mappings".format(spec_path))

	planned = []
	missing = []
	target_hashes = {}

	def source_for(relative_value, context):
		relative = _safe_relative_content_path(relative_value, context)
		source = (game_dir / relative).resolve()
		if not _path_is_within(source, game_dir):
			raise DeployError("{} escapes the game directory: {}".format(context, relative_value))
		if not source.is_file():
			missing.append(relative.as_posix())
			return None, relative
		return source, relative

	def add(source, source_relative, target, file_hash, datum_name, logical_name):
		target = _safe_relative_content_path(Path(target).as_posix(), "static browser asset target")
		previous_hash = target_hashes.get(target.as_posix())
		if previous_hash is not None and previous_hash != file_hash:
			raise DeployError("static browser assets collide at {}".format(target))
		target_hashes[target.as_posix()] = file_hash
		planned.append(
			{
				"datum": datum_name,
				"logical_name": logical_name,
				"md5": file_hash,
				"source": source_relative.as_posix(),
				"target": target.as_posix(),
				"_source_path": source,
			}
		)

	for datum_name, assets in sorted(spec["simple"].items()):
		_validate_browser_asset_name(datum_name, "simple browser asset datum")
		if not isinstance(assets, dict):
			raise DeployError("simple browser asset datum {} must be a mapping".format(datum_name))
		for logical_name, source_value in sorted(assets.items()):
			_validate_browser_asset_name(logical_name, datum_name)
			source, source_relative = source_for(source_value, datum_name)
			if source is None:
				continue
			file_hash = md5_file(source)
			extension = Path(logical_name).suffix
			add(
				source,
				source_relative,
				Path(file_hash[:2]) / "asset.{}{}".format(file_hash, extension),
				file_hash,
				datum_name,
				logical_name,
			)

	for datum_name, datum_spec in sorted(spec["namespaced"].items()):
		_validate_browser_asset_name(datum_name, "namespaced browser asset datum")
		if not isinstance(datum_spec, dict):
			raise DeployError("namespaced browser asset datum {} must be a mapping".format(datum_name))
		assets = datum_spec.get("assets")
		parents = datum_spec.get("parents")
		if not isinstance(assets, dict) or not isinstance(parents, dict):
			raise DeployError("namespaced browser asset datum {} needs assets and parents mappings".format(datum_name))
		children = []
		children_complete = True
		for logical_name, source_value in sorted(assets.items()):
			_validate_browser_asset_name(logical_name, datum_name)
			source, source_relative = source_for(source_value, datum_name)
			if source is None:
				children_complete = False
				continue
			children.append((logical_name, source, source_relative, md5_file(source)))
		# Leaving one child out would derive a namespace which the DM datum can
		# never request. Skip the group instead of publishing unreachable files.
		if not children_complete:
			continue
		# DM derives the namespace only from child assets, in sorted name order.
		namespace_input = "".join(file_hash for _, _, _, file_hash in children).encode("ascii")
		namespace = hashlib.md5(namespace_input).hexdigest()
		namespace_root = Path("namespaces") / namespace[:2] / namespace
		for logical_name, source, source_relative, file_hash in children:
			add(source, source_relative, namespace_root / logical_name, file_hash, datum_name, logical_name)
		for logical_name, source_value in sorted(parents.items()):
			_validate_browser_asset_name(logical_name, datum_name)
			source, source_relative = source_for(source_value, datum_name)
			if source is None:
				continue
			file_hash = md5_file(source)
			extension = Path(logical_name).suffix
			add(
				source,
				source_relative,
				namespace_root / "asset.{}{}".format(file_hash, extension),
				file_hash,
				datum_name,
				logical_name,
			)

	return planned, sorted(set(missing))


def publish_static_browser_assets(game_dir, settings, asset_manifest_name, plan=None):
	if not settings["RSC_ENABLE_ASSET_WEBROOT"]:
		return [], []
	if plan is None:
		plan, missing = plan_static_browser_assets(game_dir)
	else:
		plan, missing = plan
	asset_root = Path(settings["RSC_PUBLISH_DIR"]).expanduser() / settings["RSC_ASSET_WEBROOT_SUBDIR"]
	for entry in plan:
		atomic_copy(entry["_source_path"], asset_root / entry["target"])
	inventory_lines = ["# browser asset inventory v2", "# build-owned; DreamDaemon must not append public files"]
	inventory_lines.extend(sorted({entry["target"] for entry in plan}))
	inventory_path = asset_root / ".manifests" / asset_manifest_name
	atomic_write(inventory_path, "\n".join(inventory_lines) + "\n")
	make_readable(inventory_path, 0o644)
	if missing:
		log("warning: {} declared static browser asset source(s) were absent; they will use browse_rsc".format(len(missing)))
	log("published {} build-owned browser asset files".format(len(plan)))
	return sorted({entry["target"] for entry in plan}), missing


def validate_archive(path, expected_rsc_size, expected_rsc_hash=None, size_mismatch_hint=None):
	path = Path(path)
	with zipfile.ZipFile(path, "r") as archive:
		entries = archive.infolist()
		if len(entries) != 1 or entries[0].filename != "tgstation.rsc":
			raise DeployError("{} has an unexpected layout".format(path))
		if entries[0].file_size != expected_rsc_size:
			message = "{} contains a different resource size: {}, expected {}".format(
				path, entries[0].file_size, expected_rsc_size
			)
			if size_mismatch_hint:
				message += "; {}".format(size_mismatch_hint)
			raise DeployError(
				message
			)
		digest = hashlib.sha256()
		with archive.open(entries[0], "r") as resource:
			for chunk in iter(lambda: resource.read(1024 * 1024), b""):
				digest.update(chunk)
		archive_hash = digest.hexdigest()
	if expected_rsc_hash is not None and archive_hash != expected_rsc_hash:
		raise DeployError(
			"archive {} contains rsc sha256 {}, expected {}".format(
				path, archive_hash, expected_rsc_hash
			)
		)
	return archive_hash


def validate_writable_directory(path, minimum_free_bytes, additional_required_bytes=0):
	path = ensure_public_directory(path)
	fd = None
	probe_name = None
	try:
		fd, probe_name = tempfile.mkstemp(prefix=".rsc-write-test-", dir=str(path))
		with os.fdopen(fd, "wb") as probe:
			fd = None
			probe.write(b"rsc-deploy write test\n")
			probe.flush()
			os.fsync(probe.fileno())
	except OSError as error:
		raise DeployError("{} is not writable: {}".format(path, error)) from error
	finally:
		if fd is not None:
			os.close(fd)
		if probe_name:
			try:
				os.unlink(probe_name)
			except OSError:
				pass

	free_bytes = shutil.disk_usage(path).free
	required_bytes = minimum_free_bytes + additional_required_bytes
	if free_bytes < required_bytes:
		raise DeployError(
			"{} has {} free bytes, but {} are required (including the configured reserve)".format(
				path, free_bytes, required_bytes
			)
		)
	return free_bytes


def _path_is_within(path, root):
	try:
		Path(path).resolve().relative_to(Path(root).resolve())
		return True
	except ValueError:
		return False


def deployment_roots(settings):
	configured_roots = settings["RSC_DEPLOYMENT_ROOTS"]
	if configured_roots:
		return configured_roots

	config_path = Path(settings["_CONFIG_PATH"])
	for parent in config_path.parents:
		if parent.name.lower() == "configuration":
			return [(parent.parent / "Game").resolve()]
	return []


def _read_deployment_manifest(manifest_path):
	try:
		manifest = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
	except (OSError, json.JSONDecodeError) as error:
		raise DeployError("cannot read deployment manifest {}: {}".format(manifest_path, error)) from error
	archive_name = manifest.get("archive_name")
	if not isinstance(archive_name, str) or Path(archive_name).name != archive_name or not SAFE_NAME.fullmatch(archive_name):
		raise DeployError("deployment manifest {} has an unsafe archive_name".format(manifest_path))
	return manifest


def inventory_deployment_archives(root, max_depth=3):
	"""Inventory manifests referenced by deployable DMB directories below a TGS Game root."""
	root = Path(root).resolve()
	try:
		if not root.is_dir():
			raise DeployError("TGS deployment root does not exist: {}".format(root))
	except OSError as error:
		raise DeployError("cannot inspect TGS deployment root {}: {}".format(root, error)) from error

	protected = set()
	deployments = []
	dmb_count = 0
	stack = [(root, 0)]
	while stack:
		current, depth = stack.pop()
		try:
			entries = list(os.scandir(current))
		except OSError as error:
			raise DeployError("cannot list TGS deployment directory {}: {}".format(current, error)) from error

		manifest_path = None
		dmb_entries = []
		directories = []
		for entry in entries:
			try:
				if entry.name == MANIFEST_NAME and entry.is_file(follow_symlinks=True):
					manifest_path = Path(entry.path)
				elif entry.name.lower().endswith(".dmb") and entry.is_file(follow_symlinks=True):
					dmb_entries.append(entry.name)
				elif depth < max_depth and entry.is_dir(follow_symlinks=False):
					directories.append(Path(entry.path))
			except OSError as error:
				raise DeployError("cannot inspect TGS deployment entry {}: {}".format(entry.path, error)) from error

		if dmb_entries:
			dmb_count += len(dmb_entries)
			if manifest_path is None:
				raise DeployError(
					"DMB without {} found in {}; refusing to prune".format(MANIFEST_NAME, current)
				)
			manifest = _read_deployment_manifest(manifest_path)
			protected.add(manifest["archive_name"])
			deployments.append((manifest_path.resolve(), manifest))
			continue
		if manifest_path is not None:
			# A failed deployment may leave a manifest before TGS removes its
			# directory. Protecting it temporarily is safer than guessing.
			manifest = _read_deployment_manifest(manifest_path)
			protected.add(manifest["archive_name"])
			deployments.append((manifest_path.resolve(), manifest))
			continue
		for directory in sorted(directories, reverse=True):
			stack.append((directory, depth + 1))

	return protected, dmb_count, deployments


def prune_archives(game_dir, settings, current_archive_name):
	if not settings["RSC_PRUNE_ENABLED"]:
		return 0

	roots = deployment_roots(settings)
	if not roots:
		log("warning: archive cleanup skipped: could not infer the TGS Game directory")
		return 0
	game_dir = Path(game_dir).resolve()
	if not any(_path_is_within(game_dir, root) for root in roots):
		log("warning: archive cleanup skipped: current game directory is outside RSC_DEPLOYMENT_ROOTS")
		return 0

	try:
		protected = {current_archive_name}
		dmb_count = 0
		for root in roots:
			root_protected, root_dmb_count, _ = inventory_deployment_archives(root)
			protected.update(root_protected)
			dmb_count += root_dmb_count
		if not dmb_count:
			raise DeployError("no deployable DMBs were found below RSC_DEPLOYMENT_ROOTS")
	except DeployError as error:
		log("warning: archive cleanup skipped: {}".format(error))
		return 0

	publish_dir = Path(settings["RSC_PUBLISH_DIR"]).expanduser()
	if not publish_dir.is_dir():
		return 0
	try:
		archives = sorted(
			# Scoped to this instance: several TGS instances may share one publish
			# directory, and cleanup must never consider another instance's
			# archives unreferenced just because its DMBs are not below our roots.
			publish_dir.glob("{}-*.zip".format(archive_name_prefix(settings))),
			key=lambda path: path.stat().st_mtime,
			reverse=True,
		)
	except OSError as error:
		log("warning: archive cleanup skipped: cannot inventory published archives: {}".format(error))
		return 0
	unreferenced = [archive for archive in archives if archive.name not in protected]
	keep_count = settings["RSC_KEEP_UNREFERENCED"]
	grace_seconds = settings["RSC_PRUNE_GRACE_HOURS"] * 60 * 60
	cutoff = dt.datetime.now(dt.timezone.utc).timestamp() - grace_seconds
	removed = 0
	for archive in unreferenced[keep_count:]:
		try:
			if archive.is_symlink() or not archive.is_file():
				log("warning: archive cleanup ignored non-regular path {}".format(archive))
				continue
			if archive.stat().st_mtime > cutoff:
				continue
			archive.unlink()
			removed += 1
			log("removed unreferenced archive {}".format(archive.name))
		except OSError as error:
			log("warning: could not remove unreferenced archive {}: {}".format(archive, error))
	removed += _sweep_abandoned_temporaries(
		publish_dir, archive_name_prefix(settings), cutoff, settings.get("RSC_LEGACY_ALIAS_NAME")
	)
	log(
		"archive cleanup protected {} names from {} DMBs, kept {} newest unreferenced, removed {}".format(
			len(protected), dmb_count, min(keep_count, len(unreferenced)), removed
		)
	)
	return removed


def prune_release_manifests(game_dir, settings, current_release_id):
	"""Apply archive retention to immutable whole-release contracts as well."""
	if not settings["RSC_PRUNE_ENABLED"]:
		return 0
	try:
		deployments, dmb_count = _deployment_content_inventories(game_dir, settings)
	except DeployError as error:
		log("warning: release manifest cleanup skipped: {}".format(error))
		return 0
	protected = {current_release_id}
	for _, manifest in deployments:
		release_id = manifest.get("release_id")
		if isinstance(release_id, str) and SAFE_NAME.fullmatch(release_id):
			protected.add(release_id)
	release_root = Path(settings["RSC_PUBLISH_DIR"]).expanduser() / RELEASES_SUBDIR
	if not release_root.is_dir():
		return 0
	try:
		manifests = sorted(
			release_root.glob("{}-*.json".format(archive_name_prefix(settings))),
			key=lambda path: path.stat().st_mtime,
			reverse=True,
		)
	except OSError as error:
		log("warning: release manifest cleanup skipped: {}".format(error))
		return 0
	unreferenced = [path for path in manifests if path.stem not in protected]
	keep_count = settings["RSC_KEEP_UNREFERENCED"]
	cutoff = dt.datetime.now(dt.timezone.utc).timestamp() - settings["RSC_PRUNE_GRACE_HOURS"] * 60 * 60
	removed = 0
	for path in unreferenced[keep_count:]:
		try:
			if path.is_symlink() or not path.is_file() or path.stat().st_mtime > cutoff:
				continue
			path.unlink()
			removed += 1
		except OSError as error:
			log("warning: could not remove release manifest {}: {}".format(path, error))
	log("release cleanup protected {} ids from {} DMBs and removed {}".format(len(protected), dmb_count, removed))
	return removed


def _sweep_abandoned_temporaries(publish_dir, name_prefix, cutoff, alias_name=None):
	"""Remove partial files left behind when a publish was killed mid-write.

	Every temporary here is a dotfile, so the archive glob can never see it and
	an interrupted deployment would otherwise leak a full RSC-sized file. The
	grace cutoff is what keeps a concurrent deployment's in-flight temporary
	safe.
	"""
	patterns = [".{}-*.tmp".format(name_prefix), ".rsc-write-test-*"]
	if alias_name:
		# publish_legacy_alias names its temporary after the alias rather than
		# after a managed archive, so the pattern above cannot match it. Matching
		# the configured alias keeps the sweep away from unrelated dotfiles.
		patterns.append(".{}-*.tmp".format(alias_name))
	removed = 0
	for pattern in patterns:
		try:
			candidates = list(publish_dir.glob(pattern))
		except OSError as error:
			log("warning: could not inventory abandoned temporary files: {}".format(error))
			return removed
		for candidate in candidates:
			try:
				if candidate.is_symlink() or not candidate.is_file():
					continue
				if candidate.stat().st_mtime > cutoff:
					continue
				candidate.unlink()
				removed += 1
				log("removed abandoned temporary file {}".format(candidate.name))
			except OSError as error:
				log("warning: could not remove abandoned temporary {}: {}".format(candidate, error))
	return removed


def _safe_relative_content_path(value, setting_name):
	if not isinstance(value, str):
		raise DeployError("{} contains a non-string path".format(setting_name))
	normalized = value.replace("\\", "/").strip("/")
	path = Path(normalized)
	if not normalized or path.is_absolute() or ".." in path.parts:
		raise DeployError("{} contains an unsafe path: {}".format(setting_name, value))
	return Path(*path.parts)


def _deployment_content_inventories(game_dir, settings):
	roots = deployment_roots(settings)
	if not roots:
		raise DeployError("could not infer the TGS Game directory")
	game_dir = Path(game_dir).resolve()
	if not any(_path_is_within(game_dir, root) for root in roots):
		raise DeployError("current game directory is outside RSC_DEPLOYMENT_ROOTS")
	deployments = []
	dmb_count = 0
	for root in roots:
		_, root_dmb_count, root_deployments = inventory_deployment_archives(root)
		deployments.extend(root_deployments)
		dmb_count += root_dmb_count
	if not dmb_count:
		raise DeployError("no deployable DMBs were found below RSC_DEPLOYMENT_ROOTS")
	return deployments, dmb_count


def _read_browser_asset_inventory(path):
	assets = set()
	try:
		lines = Path(path).read_text(encoding="utf-8-sig").splitlines()
	except OSError as error:
		raise DeployError("cannot read browser asset inventory {}: {}".format(path, error)) from error
	for raw_line in lines:
		line = raw_line.strip()
		if not line or line.startswith("#"):
			continue
		assets.add(_safe_relative_content_path(line, "browser asset inventory"))
	return assets


def _prune_content_tree(root, protected_relative_paths, cutoff, ignored_top_level=None):
	root = Path(root)
	if not root.is_dir():
		return 0
	ignored_top_level = set(ignored_top_level or ())
	protected = {Path(path).as_posix() for path in protected_relative_paths}
	removed = 0
	try:
		files = sorted(root.rglob("*"), key=lambda path: len(path.parts), reverse=True)
	except OSError as error:
		raise DeployError("cannot inventory content store {}: {}".format(root, error)) from error
	for path in files:
		try:
			relative = path.relative_to(root)
			if relative.parts and relative.parts[0] in ignored_top_level:
				continue
			if path.is_symlink():
				continue
			if path.is_file():
				if relative.as_posix() in protected or path.stat().st_mtime > cutoff:
					continue
				path.unlink()
				removed += 1
			elif path.is_dir():
				try:
					path.rmdir()
				except OSError:
					pass
		except OSError as error:
			log("warning: could not prune content path {}: {}".format(path, error))
	return removed


def prune_content_stores(game_dir, settings, current_manifest_path, current_lobby_files):
	"""Prune only files unused by every deployable DMB, after a grace period."""
	if not settings["RSC_PRUNE_ENABLED"]:
		return 0
	try:
		return _prune_content_stores(game_dir, settings, current_manifest_path, current_lobby_files)
	except DeployError as error:
		# Cleanup is opportunistic. One unreadable, truncated or hand-edited
		# manifest belonging to a retired deployment must never be able to block
		# every future deployment of a healthy build.
		log("warning: content cleanup skipped: {}".format(error))
		return 0


def _prune_content_stores(game_dir, settings, current_manifest_path, current_lobby_files):
	deployments, dmb_count = _deployment_content_inventories(game_dir, settings)

	publish_dir = Path(settings["RSC_PUBLISH_DIR"]).expanduser()
	lobby_subdir = settings["RSC_LOBBY_MEDIA_SUBDIR"]
	asset_subdir = settings["RSC_ASSET_WEBROOT_SUBDIR"]
	lobby_root = publish_dir / lobby_subdir
	asset_root = publish_dir / asset_subdir
	asset_manifest_root = asset_root / ".manifests"
	current_manifest_path = Path(current_manifest_path).resolve()
	protected_lobby = {
		_safe_relative_content_path(path, "current lobby media") for path in current_lobby_files
	}
	protected_assets = set()
	protected_asset_manifests = set()
	legacy_lobby_inventory = False
	legacy_asset_inventory = False

	for manifest_path, manifest in deployments:
		is_current = manifest_path == current_manifest_path
		if "lobby_media_enabled" not in manifest:
			if not is_current:
				legacy_lobby_inventory = True
		elif manifest["lobby_media_enabled"]:
			files = manifest.get("lobby_media_files")
			if files is None:
				if not is_current:
					legacy_lobby_inventory = True
			else:
				for path in files:
					protected_lobby.add(_safe_relative_content_path(path, "lobby_media_files"))

		if "browser_asset_webroot_enabled" not in manifest:
			if not is_current:
				legacy_asset_inventory = True
		elif manifest["browser_asset_webroot_enabled"]:
			manifest_name = manifest.get("browser_asset_manifest")
			if not isinstance(manifest_name, str) or Path(manifest_name).name != manifest_name or not SAFE_NAME.fullmatch(manifest_name):
				if not is_current:
					legacy_asset_inventory = True
				continue
			protected_asset_manifests.add(Path(manifest_name))
			inventory_path = asset_manifest_root / manifest_name
			if inventory_path.is_file():
				for relative_path in _read_browser_asset_inventory(inventory_path):
					protected_assets.add(relative_path)
					protected_assets.add(Path(relative_path.as_posix() + ".gz"))
			elif not is_current:
				# The DMB declares an inventory but the server never wrote one,
				# so nothing is known about what it serves. Protecting an empty
				# set would delete files a running round still needs.
				legacy_asset_inventory = True

	grace_seconds = settings["RSC_PRUNE_GRACE_HOURS"] * 60 * 60
	cutoff = dt.datetime.now(dt.timezone.utc).timestamp() - grace_seconds
	removed = 0
	if legacy_lobby_inventory:
		log("warning: lobby-media cleanup skipped while a deployable DMB has no content inventory")
	else:
		removed += _prune_content_tree(lobby_root, protected_lobby, cutoff)
	if legacy_asset_inventory:
		log("warning: browser-assets cleanup skipped while a deployable DMB has no content inventory")
	else:
		removed += _prune_content_tree(asset_root, protected_assets, cutoff, ignored_top_level={".manifests"})
		removed += _prune_content_tree(asset_manifest_root, protected_asset_manifests, cutoff)
	log("content cleanup protected assets from {} DMBs and removed {} stale files".format(dmb_count, removed))
	return removed


def collect_lobby_media(game_dir, config_root):
	media = {}

	def add_tree(relative_root, extensions):
		root = config_root / relative_root
		if not root.is_dir():
			return
		for source in sorted(root.rglob("*")):
			if source.is_file() and source.suffix.lower() in extensions:
				key = (Path("config") / source.relative_to(config_root)).as_posix()
				media[key] = source

	add_tree(Path("title_screens"), LOBBY_IMAGE_EXTENSIONS)
	add_tree(Path("title_music") / "sounds", LOBBY_AUDIO_EXTENSIONS)

	round_music_list = game_dir / "strings" / "round_start_sounds.txt"
	if round_music_list.is_file():
		for raw_line in round_music_list.read_text(encoding="utf-8-sig").splitlines():
			relative_path = raw_line.strip().replace("\\", "/")
			if not relative_path or relative_path.startswith("#"):
				continue
			# The list is repository content, but it ends up naming files copied
			# into a public webroot, so it gets the same sandbox as every other
			# path input. A bad line drops that one track instead of failing a
			# deployment over the lobby playlist.
			try:
				safe_path = _safe_relative_content_path(relative_path, "strings/round_start_sounds.txt")
			except DeployError as error:
				log("warning: ignoring lobby music entry: {}".format(error))
				continue
			source = game_dir / safe_path
			if source.is_file() and source.suffix.lower() in LOBBY_AUDIO_EXTENSIONS:
				media[safe_path.as_posix()] = source
	return media


def plan_lobby_media(game_dir, settings):
	if not settings["RSC_PUBLISH_LOBBY_MEDIA"]:
		return {}
	config_root = settings["_CONFIG_PATH"].parent
	plan = {}
	for source_key, source in collect_lobby_media(game_dir, config_root).items():
		file_hash = sha256_file(source)
		extension = source.suffix.lower()
		relative_target = Path(file_hash[:2]) / "asset.{}{}".format(file_hash, extension)
		plan[source_key] = (source, relative_target, file_hash)
	return plan


def publish_lobby_media(game_dir, settings, media_plan=None):
	config_root = settings["_CONFIG_PATH"].parent
	manifest_path = config_root / "lobby_media.json"
	if not settings["RSC_PUBLISH_LOBBY_MEDIA"]:
		try:
			manifest_path.unlink()
		except FileNotFoundError:
			pass
		log("disabled external lobby media manifest")
		return 0, 0, []

	publish_dir = Path(settings["RSC_PUBLISH_DIR"]).expanduser()
	media_subdir = settings["RSC_LOBBY_MEDIA_SUBDIR"]
	media_root = publish_dir / media_subdir
	public_root = "{}/{}".format(settings["RSC_PUBLIC_BASE_URL"], media_subdir)
	mappings = {}
	total_size = 0
	published_hashes = set()
	if media_plan is None:
		media_plan = plan_lobby_media(game_dir, settings)
	for source_key, (source, relative_target, file_hash) in media_plan.items():
		atomic_copy(source, media_root / relative_target)
		mappings[source_key] = "{}/{}".format(public_root, relative_target.as_posix())
		if file_hash not in published_hashes:
			total_size += source.stat().st_size
			published_hashes.add(file_hash)

	payload = {
		"assets": mappings,
		"generated_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
		"version": 1,
	}
	atomic_write(manifest_path, json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
	make_readable(manifest_path, 0o644)
	log("published {} lobby media mappings ({} unique bytes)".format(len(mappings), total_size))
	return len(mappings), total_size, sorted(path.as_posix() for _, path, _ in media_plan.values())


def remove_managed_asset_config(text):
	start = text.find(ASSET_CONFIG_BEGIN)
	if start >= 0:
		end = text.find(ASSET_CONFIG_END, start)
		if end < 0:
			raise DeployError("managed browser asset block is incomplete in resources.txt")
		end += len(ASSET_CONFIG_END)
		text = text[:start].rstrip() + "\n" + text[end:].lstrip()
	return text.rstrip() + "\n"


def require_asset_config(settings):
	"""Return the managed resources.txt path, refusing to continue without it."""
	resources_path = settings["_CONFIG_PATH"].parent / "entries" / "resources.txt"
	if settings["RSC_ENABLE_ASSET_WEBROOT"] and not resources_path.is_file():
		raise DeployError("{} is missing; cannot configure webroot asset transport".format(resources_path))
	return resources_path


def configure_asset_webroot(settings):
	resources_path = require_asset_config(settings)
	if not resources_path.is_file():
		return
	original_text = resources_path.read_text(encoding="utf-8-sig")
	# Managed values are appended and therefore take precedence while enabled.
	# Keep the operator's original ASSET_* lines intact so removing our block
	# restores their configuration exactly.
	text = remove_managed_asset_config(original_text)
	if not settings["RSC_ENABLE_ASSET_WEBROOT"]:
		if text != original_text:
			atomic_write(resources_path, text)
			log("disabled managed browser asset webroot configuration")
		return

	publish_dir = Path(settings["RSC_PUBLISH_DIR"]).expanduser()
	asset_subdir = settings["RSC_ASSET_WEBROOT_SUBDIR"]
	asset_webroot = publish_dir / asset_subdir
	free_bytes = validate_writable_directory(asset_webroot, settings["RSC_MIN_FREE_BYTES"])
	ensure_public_directory(asset_webroot / ".manifests")
	webroot_value = asset_webroot.as_posix().rstrip("/") + "/"
	url_value = "{}/{}/".format(settings["RSC_PUBLIC_BASE_URL"], asset_subdir)
	text += "\n{}\n".format(ASSET_CONFIG_BEGIN)
	text += "ASSET_TRANSPORT webroot\n"
	text += "ASSET_CDN_WEBROOT {}\n".format(webroot_value)
	text += "ASSET_CDN_URL {}\n".format(url_value)
	text += "{}\n".format(ASSET_CONFIG_END)
	atomic_write(resources_path, text)
	log("configured build-owned browser assets at {} ({} free bytes)".format(url_value, free_bytes))


def verify_public_url(url, expected_size=None, timeout=10, retry_delays=VERIFY_RETRY_DELAYS):
	"""Confirm the HTTP server actually serves what was just written to disk.

	A publish directory which is not the one behind RSC_PUBLIC_BASE_URL, a
	missing nginx location and a 403 all look like a completely successful
	deployment from the filesystem side, while every client silently falls back
	to downloading resources through DreamDaemon. This is advisory: the web
	server may legitimately be unreachable from the TGS host, so a failure warns
	rather than rejecting a DMB whose archive is present.

	A refused, reset or timed-out connection is retried with a short backoff,
	because a deployment is exactly when the web server is likely to be
	reloading. A 4xx answer is reported immediately: the server is up and has
	already given its verdict, so waiting cannot change it.
	"""
	request = urllib.request.Request(url, method="HEAD")
	for attempt in range(len(retry_delays) + 1):
		try:
			with urllib.request.urlopen(request, timeout=timeout) as response:
				status = getattr(response, "status", None) or response.getcode()
				length = response.headers.get("Content-Length")
		except urllib.error.HTTPError as error:
			if 400 <= error.code < 500:
				log("warning: {} is published but the web server answered HTTP {}".format(url, error.code))
				return False
			failure = "the web server answered HTTP {}".format(error.code)
		except (urllib.error.URLError, OSError, ValueError) as error:
			failure = "could not be reached: {}".format(error)
		else:
			if status is not None and not 200 <= int(status) < 300:
				log("warning: {} answered HTTP {}".format(url, status))
				return False
			if expected_size is not None and length is not None and int(length) != expected_size:
				log(
					"warning: {} serves {} bytes, but {} were published; the web server is "
					"probably rooted at a different directory".format(url, length, expected_size)
				)
				return False
			log("verified {} over HTTP".format(url))
			return True
		if attempt >= len(retry_delays):
			log("warning: could not verify {} over HTTP: {}".format(url, failure))
			return False
		time.sleep(retry_delays[attempt])
	return False


def verify_public_urls(urls, expected_size=None):
	"""Verify every URL clients may receive and retain each mirror's verdict."""
	return {url: verify_public_url(url, expected_size=expected_size) for url in urls}


def verify_component_representative(settings, subdir, relative_path, expected_size):
	"""Verify one immutable file through every frontend for a release component."""
	if relative_path is None:
		return {}
	relative_path = Path(relative_path).as_posix().lstrip("/")
	urls = ["{}/{}/{}".format(base_url, subdir, relative_path) for base_url in settings["RSC_PUBLIC_BASE_URLS"]]
	return verify_public_urls(urls, expected_size=expected_size)


def verification_succeeded(component_results):
	return all(all(results.values()) for results in component_results.values() if results)


def probe_public_base_url(base_url, timeout=10, retry_delays=VERIFY_RETRY_DELAYS):
	"""Check that something answers at RSC_PUBLIC_BASE_URL before compiling.

	Any HTTP answer proves the host and the port, which is what a typo in the
	setting usually breaks. It does NOT prove the route: a 404 here is equally
	consistent with a healthy mirror which is simply empty until the first
	publication and with a location block nobody ever added. The status therefore
	carries no verdict at this stage - a disabled directory listing answers 403,
	an empty mirror answers 404, and both are normal. Only silence is worth a
	warning, and never a failure - the web server may be unreachable from the TGS
	host by design, and verify_public_url checks the archive URL for real once it
	exists.
	"""
	request = urllib.request.Request(base_url, method="HEAD")
	for attempt in range(len(retry_delays) + 1):
		try:
			with urllib.request.urlopen(request, timeout=timeout) as response:
				status = getattr(response, "status", None) or response.getcode()
		except urllib.error.HTTPError as error:
			status = error.code
		except (urllib.error.URLError, OSError, ValueError) as error:
			if attempt >= len(retry_delays):
				log(
					"warning: {} did not answer a HEAD request: {}; publication itself is "
					"unaffected, but clients will fall back to DreamDaemon if this URL stays "
					"unreachable".format(base_url, error)
				)
				return False
			time.sleep(retry_delays[attempt])
			continue
		log(
			"the web server behind {} answered HTTP {} (host and port confirmed; the status "
			"is not a verdict on the route, the archive URL is verified after publish)".format(base_url, status)
		)
		return True
	return False


def publish_legacy_alias(publish_dir, archive_path, alias_name):
	"""Point the unversioned fallback name at the archive this deployment uses.

	Managed builds embed their own immutable URLs, so this only serves clients
	which fall back to EXTERNAL_RSC_URLS: unmanaged builds, and deployments made
	while external publishing was switched off. A hard link keeps the alias free
	of extra storage; the copy fallback exists for filesystems without them.
	A failure here never fails the deployment, because the managed URL is what
	the DMB being published actually references.
	"""
	if not alias_name:
		return None
	alias_path = Path(publish_dir) / alias_name
	archive_path = Path(archive_path)
	if alias_path.name == archive_path.name:
		return None
	fd, temporary_name = tempfile.mkstemp(prefix=".{}-".format(alias_name), suffix=".tmp", dir=str(publish_dir))
	os.close(fd)
	try:
		os.unlink(temporary_name)
		try:
			os.link(str(archive_path), temporary_name)
		except (AttributeError, NotImplementedError, OSError):
			shutil.copyfile(str(archive_path), temporary_name)
		os.chmod(temporary_name, 0o644)
		os.replace(temporary_name, str(alias_path))
	except OSError as error:
		try:
			os.unlink(temporary_name)
		except OSError:
			pass
		log("warning: could not refresh the {} fallback alias: {}".format(alias_name, error))
		return None
	log("refreshed the unversioned fallback alias {}".format(alias_path))
	return alias_name


def _write_archive(publish_dir, final_path, rsc_path, rsc_size, rsc_hash, compression_level):
	fd, temporary_name = tempfile.mkstemp(prefix=".{}-".format(final_path.name), suffix=".tmp", dir=str(publish_dir))
	os.close(fd)
	temporary_path = Path(temporary_name)
	try:
		compression = zipfile.ZIP_STORED if compression_level == 0 else zipfile.ZIP_DEFLATED
		with zipfile.ZipFile(
			temporary_path,
			"w",
			compression=compression,
			compresslevel=compression_level if compression == zipfile.ZIP_DEFLATED else None,
			allowZip64=True,
		) as archive:
			archive.write(rsc_path, arcname="tgstation.rsc")
		archive_rsc_hash = validate_archive(
			temporary_path,
			expected_rsc_size=rsc_size,
			expected_rsc_hash=rsc_hash,
		)
		with temporary_path.open("rb+") as archive_file:
			os.fsync(archive_file.fileno())
		make_readable(temporary_path, 0o644)
		os.replace(str(temporary_path), str(final_path))
		return archive_rsc_hash
	except Exception:
		try:
			temporary_path.unlink()
		except OSError:
			pass
		raise


def write_archive(publish_dir, final_path, rsc_path, rsc_size, rsc_hash, compression_level, retry_delay=ARCHIVE_WRITE_RETRY_DELAY):
	"""Write the archive, retrying a transient storage failure exactly once.

	Publish directories are routinely on network storage, where a single write
	can fail while the mount recovers. Only OSError is retried: a size or digest
	mismatch is a verdict about the build, and repeating it would just fail
	twice.
	"""
	try:
		return _write_archive(publish_dir, final_path, rsc_path, rsc_size, rsc_hash, compression_level)
	except OSError as error:
		log("warning: could not write {}: {}; retrying once in {} seconds".format(final_path, error, retry_delay))
	time.sleep(retry_delay)
	return _write_archive(publish_dir, final_path, rsc_path, rsc_size, rsc_hash, compression_level)


def release_manifest_payload(manifest, settings):
	"""Return the immutable contract activated by the mutable latest pointer."""
	asset_subdir = settings["RSC_ASSET_WEBROOT_SUBDIR"]
	lobby_subdir = settings["RSC_LOBBY_MEDIA_SUBDIR"]
	return {
		"schema_version": RELEASE_MANIFEST_SCHEMA_VERSION,
		"release_id": manifest["release_id"],
		"revision": manifest["revision"],
		"components": {
			"browser": {
				"base_urls": ["{}/{}/".format(url, asset_subdir) for url in settings["RSC_PUBLIC_BASE_URLS"]],
				"build_owned_files": manifest.get("browser_asset_files", []),
				"enabled": manifest["browser_asset_webroot_enabled"],
				"inventory": manifest.get("browser_asset_manifest"),
				"missing_declared_sources": manifest.get("browser_asset_missing_sources", []),
				"runtime_write_policy": "read-only",
			},
			"lobby": {
				"base_urls": ["{}/{}/".format(url, lobby_subdir) for url in settings["RSC_PUBLIC_BASE_URLS"]],
				"enabled": manifest["lobby_media_enabled"],
				"files": manifest.get("lobby_media_files", []),
			},
			"rsc": {
				"archive_name": manifest["archive_name"],
				"archive_rsc_sha256": manifest["archive_rsc_sha256"],
				"public_urls": manifest.get("public_urls") or [manifest["public_url"]],
				"rsc_size": manifest["rsc_size"],
				"zip_size": manifest["zip_size"],
			},
		},
	}


def publish_release_manifest(manifest, settings):
	payload = release_manifest_payload(manifest, settings)
	publish_dir = Path(settings["RSC_PUBLISH_DIR"]).expanduser()
	relative_path = Path(RELEASES_SUBDIR) / "{}.json".format(manifest["release_id"])
	release_path = publish_dir / relative_path
	serialized = json.dumps(payload, indent=2, sort_keys=True) + "\n"
	if release_path.is_file():
		try:
			existing = json.loads(release_path.read_text(encoding="utf-8"))
		except (OSError, json.JSONDecodeError) as error:
			raise DeployError("cannot validate immutable release manifest {}: {}".format(release_path, error)) from error
		if existing != payload:
			raise DeployError("immutable release {} already exists with different components".format(manifest["release_id"]))
	else:
		atomic_write(release_path, serialized)
		make_readable(release_path, 0o644)
	manifest["release_manifest"] = relative_path.as_posix()
	return payload


def publish(args):
	game_dir = Path(args.game_dir).resolve()
	settings = load_settings(game_dir, args.config)
	if settings is None:
		return

	manifest_path = game_dir / MANIFEST_NAME
	if not manifest_path.is_file():
		raise DeployError("{} is missing; PreCompile did not prepare this build".format(manifest_path))
	manifest = _read_deployment_manifest(manifest_path)
	rsc_path = game_dir / "tgstation.rsc"
	if not rsc_path.is_file():
		raise DeployError("DreamMaker did not create {}".format(rsc_path))
	rsc_hash = sha256_file(rsc_path)
	rsc_size = rsc_path.stat().st_size

	publish_dir = Path(settings["RSC_PUBLISH_DIR"]).expanduser()
	if not publish_dir.is_absolute():
		raise DeployError("RSC_PUBLISH_DIR must be an absolute path")
	final_path = publish_dir / manifest["archive_name"]
	media_plan = plan_lobby_media(game_dir, settings)
	browser_plan = ([], [])
	if settings["RSC_ENABLE_ASSET_WEBROOT"]:
		browser_plan = plan_static_browser_assets(game_dir)
	current_lobby_files = sorted(path.as_posix() for _, path, _ in media_plan.values())
	# Prune before checking free space so old, unreferenced archives cannot
	# or content-addressed browser/lobby files cannot deadlock a deployment by
	# consuming the room needed for their replacement.
	prune_archives(game_dir, settings, manifest["archive_name"])
	prune_release_manifests(game_dir, settings, manifest["release_id"])
	prune_content_stores(game_dir, settings, manifest_path, current_lobby_files)
	missing_lobby_bytes = 0
	seen_lobby_targets = set()
	for source, relative_target, _ in media_plan.values():
		if relative_target in seen_lobby_targets:
			continue
		seen_lobby_targets.add(relative_target)
		if not (publish_dir / settings["RSC_LOBBY_MEDIA_SUBDIR"] / relative_target).is_file():
			missing_lobby_bytes += source.stat().st_size
	missing_browser_bytes = 0
	seen_browser_targets = set()
	for entry in browser_plan[0]:
		target = entry["target"]
		if target in seen_browser_targets:
			continue
		seen_browser_targets.add(target)
		if not (publish_dir / settings["RSC_ASSET_WEBROOT_SUBDIR"] / target).is_file():
			missing_browser_bytes += entry["_source_path"].stat().st_size
	validate_writable_directory(
		publish_dir,
		settings["RSC_MIN_FREE_BYTES"],
		additional_required_bytes=(0 if final_path.exists() else rsc_size) + missing_lobby_bytes + missing_browser_bytes,
	)
	archive_reused = False
	archive_rsc_hash = rsc_hash
	if final_path.exists():
		# DreamMaker writes compilation timestamps into tgstation.rsc, so two
		# builds from identical inputs are not byte-for-byte reproducible. The
		# content-addressed input fingerprint selects the archive; size still
		# catches resources being added or removed by conditional compilation.
		archive_rsc_hash = validate_archive(
			final_path,
			expected_rsc_size=rsc_size,
			size_mismatch_hint=(
				"the resource input fingerprint is stale or conditional compilation "
				"changed the embedded resource set"
			),
		)
		archive_reused = True
		log(
			"immutable archive {} has the expected RSC size; reusing it "
			"(archive sha256 {}, compiled sha256 {})".format(final_path, archive_rsc_hash, rsc_hash)
		)
	else:
		archive_rsc_hash = write_archive(
			publish_dir,
			final_path,
			rsc_path,
			rsc_size,
			rsc_hash,
			settings["RSC_COMPRESSION_LEVEL"],
		)

	manifest.update(
		{
			"archive_reused": archive_reused,
			"archive_rsc_sha256": archive_rsc_hash,
			"rsc_sha256": rsc_hash,
			"rsc_size": rsc_size,
			"zip_size": final_path.stat().st_size,
		}
	)
	media_count, media_size, lobby_media_files = publish_lobby_media(game_dir, settings, media_plan=media_plan)
	manifest["lobby_media_count"] = media_count
	manifest["lobby_media_size"] = media_size
	manifest["lobby_media_files"] = lobby_media_files
	configure_asset_webroot(settings)
	if settings["RSC_ENABLE_ASSET_WEBROOT"]:
		browser_asset_files, browser_asset_missing_sources = publish_static_browser_assets(
			game_dir, settings, manifest["browser_asset_manifest"], plan=browser_plan
		)
	else:
		browser_asset_files, browser_asset_missing_sources = [], []
	manifest["browser_asset_files"] = browser_asset_files
	manifest["browser_asset_missing_sources"] = browser_asset_missing_sources
	if settings["RSC_VERIFY_PUBLIC_URL"]:
		public_url_verification = verify_public_urls(
			manifest.get("public_urls") or [manifest["public_url"]], expected_size=manifest["zip_size"]
		)
		manifest["public_url_verification"] = public_url_verification
		manifest["public_url_verified"] = all(public_url_verification.values())
		browser_representative = next(
			(entry for entry in browser_plan[0] if entry["logical_name"] == "tgui.bundle.js"),
			browser_plan[0][0] if browser_plan[0] else None,
		)
		lobby_representative = next(iter(media_plan.values()), None)
		component_verification = {
			"rsc": public_url_verification,
			"browser": verify_component_representative(
				settings,
				settings["RSC_ASSET_WEBROOT_SUBDIR"],
				browser_representative["target"] if browser_representative else None,
				browser_representative["_source_path"].stat().st_size if browser_representative else None,
			),
			"lobby": verify_component_representative(
				settings,
				settings["RSC_LOBBY_MEDIA_SUBDIR"],
				lobby_representative[1] if lobby_representative else None,
				lobby_representative[0].stat().st_size if lobby_representative else None,
			),
		}
		manifest["component_url_verification"] = component_verification
		manifest["component_urls_verified"] = verification_succeeded(component_verification)
		if settings["RSC_REQUIRE_PUBLIC_VERIFICATION"] and (
			not manifest["component_urls_verified"] or browser_asset_missing_sources
		):
			raise DeployError("release component verification failed; refusing to activate {}".format(manifest["release_id"]))
	# The alias is a mutable pointer consumed by unmanaged clients, so it moves
	# only after the release has survived verification: a rejected release must
	# leave the previous fallback archive untouched.
	manifest["legacy_alias"] = publish_legacy_alias(
		publish_dir, final_path, settings["RSC_LEGACY_ALIAS_NAME"]
	)
	release_payload = publish_release_manifest(manifest, settings)
	# This copy travels with the DMB. Future cleanup uses it (plus the browser
	# inventory created by this build) to protect every file needed by deployable versions.
	atomic_write(manifest_path, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
	# Namespaced like the archives themselves: several TGS instances may share one
	# publish directory, and an unnamespaced report would describe whichever of
	# them deployed last.
	latest_manifest = publish_dir / "{}-latest.json".format(archive_name_prefix(settings))
	atomic_write(latest_manifest, json.dumps(manifest, indent=2, sort_keys=True) + "\n")
	make_readable(latest_manifest, 0o644)
	# This is the single activation point for the complete release. It is written
	# last, after every immutable component and its manifest are durable.
	active_manifest = publish_dir / "{}-active.json".format(archive_name_prefix(settings))
	active_payload = {
		"activated_utc": dt.datetime.now(dt.timezone.utc).isoformat(),
		"release_id": manifest["release_id"],
		"release_manifest": manifest["release_manifest"],
		"schema_version": release_payload["schema_version"],
	}
	atomic_write(active_manifest, json.dumps(active_payload, indent=2, sort_keys=True) + "\n")
	make_readable(active_manifest, 0o644)

	log(
		"published {} ({} bytes, archive rsc sha256 {}, compiled rsc sha256 {})".format(
			final_path,
			final_path.stat().st_size,
			manifest["archive_rsc_sha256"],
			manifest["rsc_sha256"],
		)
	)


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	subparsers = parser.add_subparsers(dest="command", required=True)

	prepare_parser = subparsers.add_parser("prepare", help="embed a unique URL before DreamMaker runs")
	prepare_parser.add_argument("--game-dir", required=True)
	prepare_parser.add_argument("--revision", default="")
	prepare_parser.add_argument("--config", help="host settings file; defaults to GAME_DIR/config/rsc_deploy.env")
	prepare_parser.set_defaults(handler=prepare)

	publish_parser = subparsers.add_parser("publish", help="publish the matching archive after compilation")
	publish_parser.add_argument("--game-dir", required=True)
	publish_parser.add_argument("--config", help="host settings file; defaults to GAME_DIR/config/rsc_deploy.env")
	publish_parser.set_defaults(handler=publish)

	args = parser.parse_args()
	try:
		args.handler(args)
	except (DeployError, OSError, ValueError, zipfile.BadZipFile, json.JSONDecodeError) as error:
		message = "[rsc-deploy] ERROR: {}".format(error)
		print(message, file=sys.stderr, flush=True)
		# TGS surfaces stdout in the job log; keep the failure visible in both.
		print(message, flush=True)
		return 1
	return 0


if __name__ == "__main__":
	sys.exit(main())
