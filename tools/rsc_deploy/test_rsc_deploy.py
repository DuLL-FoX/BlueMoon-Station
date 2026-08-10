#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import urllib.error
import zipfile


SCRIPT = Path(__file__).with_name("rsc_deploy.py")
sys.path.insert(0, str(SCRIPT.parent))
import rsc_deploy  # noqa: E402


def dreammaker_rsc_fixture(compilation_timestamp):
	"""Model DreamMaker resource records with build-time and source mtimes."""
	entries = (
		(b"icons/test.dmi", 1_720_000_001, b"DMI resource contents"),
		(b"sound/test.ogg", 1_720_000_002, b"OggS resource contents"),
	)
	result = bytearray(b"RSC fixture\0")
	for name, source_mtime, payload in entries:
		result.extend(struct.pack("<II", compilation_timestamp, source_mtime))
		result.extend(struct.pack("<II", len(name), len(payload)))
		result.extend(name)
		result.extend(payload)
	return bytes(result)


class RscDeployIntegrationTest(unittest.TestCase):
	def test_archive_media_and_webroot_are_published_together(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			game_dir = root / "Game" / "current" / "A"
			config_root = root / "Configuration" / "GameStaticFiles" / "config"
			publish_dir = root / "nginx" / "byond_rsc"
			settings_path = config_root / "rsc_deploy.env"

			(game_dir / "code").mkdir(parents=True)
			(game_dir / "strings").mkdir(parents=True)
			(game_dir / "sound" / "ambience").mkdir(parents=True)
			(config_root / "entries").mkdir(parents=True)
			(config_root / "title_screens").mkdir(parents=True)
			(config_root / "title_music" / "sounds").mkdir(parents=True)

			(game_dir / "code" / "_compile_options.dm").write_text(
				"#define DEPLOYMENT_RSC_URLS null\n", encoding="utf-8"
			)
			(game_dir / "tgstation.dme").write_text(
				'#include "code\\_compile_options.dm"\n', encoding="utf-8"
			)
			compiled_rsc = dreammaker_rsc_fixture(1_720_000_100)
			(game_dir / "tgstation.rsc").write_bytes(compiled_rsc)
			(game_dir / "tgstation.dmb").write_bytes(b"compiled game")
			(game_dir / "strings" / "round_start_sounds.txt").write_text(
				"sound/ambience/title1.ogg\n", encoding="utf-8"
			)
			round_music = b"round music"
			lobby_music = b"custom lobby music"
			lobby_image = b"GIF89a lobby background"
			(game_dir / "sound" / "ambience" / "title1.ogg").write_bytes(round_music)
			(config_root / "title_music" / "sounds" / "custom.ogg").write_bytes(lobby_music)
			(config_root / "title_screens" / "cyberpunk.gif").write_bytes(lobby_image)
			(config_root / "title_screens" / "cyberpunk-copy.gif").write_bytes(lobby_image)
			(config_root / "entries" / "resources.txt").write_text(
				"# Browser assets\n"
				"#ASSET_TRANSPORT webroot\n"
				"#ASSET_CDN_WEBROOT data/asset-store/\n"
				"ASSET_TRANSPORT simple\n"
				"ASSET_CDN_WEBROOT old-assets/\n"
				"ASSET_CDN_URL http://old.example.test/\n",
				encoding="utf-8",
			)
			settings_path.write_text(
				"RSC_PUBLIC_BASE_URL=http://download.example.test/byond_rsc\n"
				"RSC_PUBLIC_MIRROR_BASE_URLS=https://mirror-one.example.test/rsc/;"
				"https://mirror-two.example.test/byond_rsc\n"
				"RSC_PUBLISH_DIR={}\n"
				"RSC_ARCHIVE_PREFIX=Moon-Test\n"
				"RSC_COMPRESSION_LEVEL=0\n"
				"RSC_MIN_FREE_BYTES=0\n"
				"RSC_KEEP_UNREFERENCED=0\n"
				"RSC_PRUNE_GRACE_HOURS=0\n"
				"RSC_PUBLISH_LOBBY_MEDIA=1\n"
				"RSC_VERIFY_PUBLIC_URL=0\n"
				"RSC_ENABLE_ASSET_WEBROOT=1\n".format(publish_dir.as_posix()),
				encoding="utf-8",
			)

			common = ["--game-dir", str(game_dir), "--config", str(settings_path)]
			original_compile_options = (game_dir / "code" / "_compile_options.dm").read_text(encoding="utf-8")
			subprocess.run(
				[sys.executable, str(SCRIPT), "prepare", *common, "--revision", "abcdef0123456789"],
				check=True,
			)
			build_manifest = json.loads((game_dir / ".rsc-deploy.json").read_text(encoding="utf-8"))
			self.assertEqual(
				(game_dir / "code" / "_compile_options.dm").read_text(encoding="utf-8"),
				original_compile_options,
			)
			self.assertEqual(
				(game_dir / "tgstation.dme").read_text(encoding="utf-8").count(
					'#include ".rsc-deployment.dm"'
				),
				1,
			)
			self.assertIn(
				build_manifest["public_url"],
				(game_dir / ".rsc-deployment.dm").read_text(encoding="utf-8"),
			)
			expected_public_urls = [
				"http://download.example.test/byond_rsc/{}".format(build_manifest["archive_name"]),
				"https://mirror-one.example.test/rsc/{}".format(build_manifest["archive_name"]),
				"https://mirror-two.example.test/byond_rsc/{}".format(build_manifest["archive_name"]),
			]
			self.assertEqual(build_manifest["public_urls"], expected_public_urls)
			generated_defines = (game_dir / ".rsc-deployment.dm").read_text(encoding="utf-8")
			self.assertIn("#define DEPLOYMENT_RSC_URLS list(", generated_defines)
			self.assertIn("#define DEPLOYMENT_ASSET_MANIFEST_NAME \"Moon-Test-", generated_defines)
			self.assertIn("#define DEPLOYMENT_RELEASE_ID \"Moon-Test-", generated_defines)
			for public_url in expected_public_urls:
				self.assertIn(public_url, generated_defines)
			# The instance namespace is visible in the name so cleanup can tell
			# its own archives from another instance's in a shared directory.
			name_prefix = rsc_deploy.archive_name_prefix(rsc_deploy.load_settings(game_dir, settings_path))
			self.assertTrue(name_prefix.startswith("Moon-Test-"))
			self.assertEqual(
				build_manifest["archive_name"],
				"{}-{}.zip".format(name_prefix, build_manifest["archive_inputs_sha256"]),
			)

			# A pure logic change must retain the resource URL.
			(game_dir / "code" / "code_only.dm").write_text("/proc/code_only_change()\n\treturn 42\n", encoding="utf-8")
			subprocess.run(
				[sys.executable, str(SCRIPT), "prepare", *common, "--revision", "different-revision"],
				check=True,
			)
			code_only_manifest = json.loads((game_dir / ".rsc-deploy.json").read_text(encoding="utf-8"))
			self.assertEqual(code_only_manifest["archive_name"], build_manifest["archive_name"])
			self.assertEqual(
				(game_dir / "tgstation.dme").read_text(encoding="utf-8").count(
					'#include ".rsc-deployment.dm"'
				),
				1,
			)

			old_game_dir = root / "Game" / "old" / "A"
			old_game_dir.mkdir(parents=True)
			(old_game_dir / "tgstation.dmb").write_bytes(b"active old game")
			protected_archive = publish_dir / "{}-protected.zip".format(name_prefix)
			stale_archive = publish_dir / "{}-stale.zip".format(name_prefix)
			# The prepare preflight already probed this directory into existence.
			publish_dir.mkdir(parents=True, exist_ok=True)
			protected_archive.write_bytes(b"referenced by active DMB")
			stale_archive.write_bytes(b"unreferenced")
			(old_game_dir / ".rsc-deploy.json").write_text(
				json.dumps({"archive_name": protected_archive.name}), encoding="utf-8"
			)

			subprocess.run([sys.executable, str(SCRIPT), "publish", *common], check=True)
			# Publishing the same content-addressed RSC again is an idempotent success.
			subprocess.run([sys.executable, str(SCRIPT), "publish", *common], check=True)
			self.assertFalse(stale_archive.exists())
			self.assertEqual(protected_archive.read_bytes(), b"referenced by active DMB")
			# Unmanaged builds still resolve EXTERNAL_RSC_URLS to the unversioned
			# name, and cleanup ran here with no grace period and nothing kept.
			legacy_alias = publish_dir / "Moon-Test.zip"
			self.assertTrue(legacy_alias.is_file())
			self.assertEqual(
				legacy_alias.read_bytes(),
				(publish_dir / build_manifest["archive_name"]).read_bytes(),
			)
			# Reconfiguring an existing instance must not duplicate the managed
			# block or retain stale active CDN settings.
			loaded_settings = rsc_deploy.load_settings(game_dir, settings_path)
			rsc_deploy.configure_asset_webroot(loaded_settings)
			rsc_deploy.configure_asset_webroot(loaded_settings)
			archive_path = publish_dir / build_manifest["archive_name"]
			with zipfile.ZipFile(archive_path) as archive:
				self.assertEqual(archive.namelist(), ["tgstation.rsc"])
				self.assertEqual(archive.read("tgstation.rsc"), (game_dir / "tgstation.rsc").read_bytes())

			media_manifest = json.loads((config_root / "lobby_media.json").read_text(encoding="utf-8"))
			expected = {
				"config/title_music/sounds/custom.ogg": lobby_music,
				"config/title_screens/cyberpunk-copy.gif": lobby_image,
				"config/title_screens/cyberpunk.gif": lobby_image,
				"sound/ambience/title1.ogg": round_music,
			}
			self.assertEqual(set(media_manifest["assets"]), set(expected))
			for source_name, source_payload in expected.items():
				url = media_manifest["assets"][source_name]
				self.assertTrue(url.startswith("http://download.example.test/byond_rsc/lobby-media/"))
				relative_path = url.split("/lobby-media/", 1)[1]
				self.assertEqual((publish_dir / "lobby-media" / relative_path).read_bytes(), source_payload)
			self.assertEqual(
				media_manifest["assets"]["config/title_screens/cyberpunk.gif"],
				media_manifest["assets"]["config/title_screens/cyberpunk-copy.gif"],
			)

			resources = (config_root / "entries" / "resources.txt").read_text(encoding="utf-8")
			self.assertEqual(resources.count("# BEGIN MANAGED EXTERNAL BROWSER ASSETS"), 1)
			self.assertEqual(resources.count("\nASSET_TRANSPORT webroot\n"), 1)
			self.assertIn("ASSET_CDN_WEBROOT {}/browser-assets/".format(publish_dir.as_posix()), resources)
			self.assertIn("ASSET_CDN_URL http://download.example.test/byond_rsc/browser-assets/", resources)
			# Operator values remain below the managed override and become active
			# again when external webroot management is disabled.
			self.assertIn("ASSET_TRANSPORT simple", resources)
			self.assertIn("ASSET_CDN_WEBROOT old-assets/", resources)
			self.assertIn("ASSET_CDN_URL http://old.example.test/", resources)
			self.assertTrue((publish_dir / "browser-assets").is_dir())
			self.assertTrue((publish_dir / "browser-assets" / ".manifests").is_dir())

			latest = json.loads((publish_dir / "{}-latest.json".format(name_prefix)).read_text(encoding="utf-8"))
			active = json.loads((publish_dir / "{}-active.json".format(name_prefix)).read_text(encoding="utf-8"))
			release = json.loads((publish_dir / active["release_manifest"]).read_text(encoding="utf-8"))
			self.assertFalse((publish_dir / "Moon-Test-latest.json").exists())
			self.assertEqual(active["release_id"], latest["release_id"])
			self.assertEqual(release["release_id"], active["release_id"])
			self.assertEqual(release["components"]["browser"]["runtime_write_policy"], "read-only")
			self.assertEqual(release["components"]["rsc"]["archive_name"], latest["archive_name"])
			self.assertTrue(latest["archive_reused"])
			self.assertEqual(latest["archive_rsc_sha256"], latest["rsc_sha256"])
			self.assertEqual(latest["lobby_media_count"], 4)
			self.assertEqual(latest["lobby_media_size"], sum(map(len, set(expected.values()))))

			# DreamMaker timestamps make repeated RSC builds bytewise different.
			# Rebuild the same resource records with another compilation time: the
			# size and source mtimes stay fixed, while the compiled bytes differ.
			original_archive = archive_path.read_bytes()
			timestamp_variant = dreammaker_rsc_fixture(1_720_000_207)
			self.assertEqual(len(timestamp_variant), len(compiled_rsc))
			self.assertNotEqual(timestamp_variant, compiled_rsc)
			(game_dir / "tgstation.rsc").write_bytes(timestamp_variant)
			result = subprocess.run(
				[sys.executable, str(SCRIPT), "publish", *common],
				check=True,
				capture_output=True,
				text=True,
			)
			self.assertIn("has the expected RSC size; reusing it", result.stdout)
			self.assertEqual(archive_path.read_bytes(), original_archive)
			latest = json.loads((publish_dir / "{}-latest.json".format(name_prefix)).read_text(encoding="utf-8"))
			self.assertNotEqual(latest["archive_rsc_sha256"], latest["rsc_sha256"])

			# A changed resource set normally changes the RSC size and must not
			# reuse an archive selected by a stale pre-compile fingerprint.
			(game_dir / "tgstation.rsc").write_bytes(b"different size")
			result = subprocess.run(
				[sys.executable, str(SCRIPT), "publish", *common],
				check=False,
				capture_output=True,
				text=True,
			)
			self.assertNotEqual(result.returncode, 0)
			self.assertIn("contains a different resource size", result.stdout)
			self.assertIn("resource input fingerprint is stale", result.stdout)
			self.assertEqual(archive_path.read_bytes(), original_archive)

			# Disabling the feature must remove settings written by an earlier
			# enabled deployment instead of leaving webroot transport active.
			loaded_settings["RSC_ENABLE_ASSET_WEBROOT"] = False
			rsc_deploy.configure_asset_webroot(loaded_settings)
			resources = (config_root / "entries" / "resources.txt").read_text(encoding="utf-8")
			self.assertNotIn("# BEGIN MANAGED EXTERNAL BROWSER ASSETS", resources)
			self.assertIn("ASSET_TRANSPORT simple", resources)
			self.assertIn("ASSET_CDN_WEBROOT old-assets/", resources)
			self.assertIn("ASSET_CDN_URL http://old.example.test/", resources)

			# Disabling lobby publication must remove the runtime switch, otherwise
			# the next server keeps emitting HTTP URLs for files no longer managed.
			loaded_settings["RSC_PUBLISH_LOBBY_MEDIA"] = False
			rsc_deploy.publish_lobby_media(game_dir, loaded_settings)
			self.assertFalse((config_root / "lobby_media.json").exists())

	def test_static_browser_assets_match_dm_webroot_paths(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			game_dir = Path(temporary_directory)
			(game_dir / "web").mkdir()
			(game_dir / "web" / "bundle.js").write_bytes(b"bundle")
			(game_dir / "web" / "child.css").write_bytes(b"child")
			(game_dir / "web" / "parent.html").write_bytes(b"parent")
			spec_path = game_dir / "browser-assets.json"
			spec_path.write_text(
				json.dumps(
					{
						"version": 1,
						"simple": {"tgui": {"bundle.js": "web/bundle.js"}},
						"namespaced": {
							"window": {
								"assets": {"child.css": "web/child.css"},
								"parents": {"parent.html": "web/parent.html"},
							}
						},
					}
				),
				encoding="utf-8",
			)

			plan, missing = rsc_deploy.plan_static_browser_assets(game_dir, spec_path=spec_path)
			self.assertEqual(missing, [])
			by_name = {entry["logical_name"]: entry for entry in plan}
			bundle_hash = hashlib.md5(b"bundle").hexdigest()
			child_hash = hashlib.md5(b"child").hexdigest()
			parent_hash = hashlib.md5(b"parent").hexdigest()
			namespace = hashlib.md5(child_hash.encode("ascii")).hexdigest()
			self.assertEqual(by_name["bundle.js"]["target"], "{}/asset.{}.js".format(bundle_hash[:2], bundle_hash))
			self.assertEqual(
				by_name["child.css"]["target"],
				"namespaces/{}/{}/child.css".format(namespace[:2], namespace),
			)
			self.assertEqual(
				by_name["parent.html"]["target"],
				"namespaces/{}/{}/asset.{}.html".format(namespace[:2], namespace, parent_hash),
			)

	def test_resource_fingerprint_tracks_files_and_static_references(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			game_dir = Path(temporary_directory)
			(game_dir / "code").mkdir()
			(game_dir / "icons").mkdir()
			(game_dir / "tgui" / "public").mkdir(parents=True)
			resource = game_dir / "icons" / "existing.dmi"
			resource.write_bytes(b"first icon")
			browser_bundle = game_dir / "tgui" / "public" / "bundle.js"
			browser_bundle.write_bytes(b"first browser bundle")
			source = game_dir / "code" / "feature.dm"
			source.write_text("/proc/example()\n\treturn 1\n", encoding="utf-8")

			initial = rsc_deploy.resource_inputs_sha256(game_dir)
			source.write_text("/proc/example()\n\treturn 2\n", encoding="utf-8")
			self.assertEqual(rsc_deploy.resource_inputs_sha256(game_dir), initial)
			resource.write_bytes(b"unreferenced icon change")
			browser_bundle.write_bytes(b"second browser bundle")
			self.assertEqual(rsc_deploy.resource_inputs_sha256(game_dir), initial)

			source.write_text("/obj/example\n\ticon = 'icons/existing.dmi'\n", encoding="utf-8")
			with_reference = rsc_deploy.resource_inputs_sha256(game_dir)
			self.assertNotEqual(with_reference, initial)

			# Compile-time variants must never collide even when they mention the
			# same resource literals and files.
			source.write_text(
				"#define ALTERNATE_RESOURCE_SET\n/obj/example\n\ticon = 'icons/existing.dmi'\n",
				encoding="utf-8",
			)
			with_build_define = rsc_deploy.resource_inputs_sha256(game_dir)
			self.assertNotEqual(with_build_define, with_reference)

			resource.write_bytes(b"changed icon")
			with_changed_resource = rsc_deploy.resource_inputs_sha256(game_dir)
			self.assertNotEqual(with_changed_resource, with_build_define)

			# The interface file is compiled too, so its static resource literals
			# must participate even though unrelated browser JS does not.
			(game_dir / "interface").mkdir()
			interface_resource = game_dir / "icons" / "interface.dmi"
			interface_resource.write_bytes(b"interface icon")
			(game_dir / "interface" / "skin.dmf").write_text(
				"icon = 'icons/interface.dmi'\n", encoding="utf-8"
			)
			with_interface_reference = rsc_deploy.resource_inputs_sha256(game_dir)
			self.assertNotEqual(with_interface_reference, with_changed_resource)
			interface_resource.write_bytes(b"changed interface icon")
			self.assertNotEqual(rsc_deploy.resource_inputs_sha256(game_dir), with_interface_reference)

	def test_resource_fingerprint_covers_nested_directories_named_like_repository_tooling(self):
		"""Real game code lives in code/…/tools/ and …/simple_animal/bot/."""
		with tempfile.TemporaryDirectory() as temporary_directory:
			game_dir = Path(temporary_directory)
			(game_dir / "code" / "game" / "items" / "tools").mkdir(parents=True)
			(game_dir / "code" / "mob" / "bot").mkdir(parents=True)
			(game_dir / "sound").mkdir()
			(game_dir / "tools").mkdir()
			crowbar = game_dir / "sound" / "crowbar.ogg"
			medbot = game_dir / "sound" / "medbot.ogg"
			crowbar.write_bytes(b"crowbar sound")
			medbot.write_bytes(b"medbot sound")
			(game_dir / "code" / "game" / "items" / "tools" / "crowbar.dm").write_text(
				"/obj/item/crowbar\n\tusesound = 'sound/crowbar.ogg'\n", encoding="utf-8"
			)
			(game_dir / "code" / "mob" / "bot" / "medbot.dm").write_text(
				"/mob/living/simple_animal/bot/medbot\n\tvoice = 'sound/medbot.ogg'\n", encoding="utf-8"
			)
			# Repository tooling at the top level stays out of the fingerprint.
			(game_dir / "tools" / "helper.dm").write_text(
				"/proc/helper()\n\treturn 'sound/crowbar.ogg'\n", encoding="utf-8"
			)

			baseline = rsc_deploy.resource_inputs_sha256(game_dir)
			crowbar.write_bytes(b"re-exported crowbar sound")
			after_crowbar = rsc_deploy.resource_inputs_sha256(game_dir)
			self.assertNotEqual(after_crowbar, baseline)
			medbot.write_bytes(b"re-recorded medbot line")
			self.assertNotEqual(rsc_deploy.resource_inputs_sha256(game_dir), after_crowbar)

	def test_resource_fingerprint_survives_an_apostrophe_before_a_literal(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			game_dir = Path(temporary_directory)
			(game_dir / "code").mkdir()
			(game_dir / "icons").mkdir()
			storage = game_dir / "icons" / "storage.dmi"
			storage.write_bytes(b"storage icons")
			(game_dir / "code" / "webbing.dm").write_text(
				"/obj/item/storage/belt\n\tname = \"Explorer's Webbing\"\n"
				"\ticon = 'icons/storage.dmi'\n",
				encoding="utf-8",
			)
			baseline = rsc_deploy.resource_inputs_sha256(game_dir)
			storage.write_bytes(b"changed storage icons")
			self.assertNotEqual(rsc_deploy.resource_inputs_sha256(game_dir), baseline)

	def test_conditional_compilation_and_includes_change_the_archive_name(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			game_dir = Path(temporary_directory)
			(game_dir / "code").mkdir()
			(game_dir / "icons").mkdir()
			(game_dir / "icons" / "optional.dmi").write_bytes(b"optional icons")
			source = game_dir / "code" / "optional.dm"
			source.write_text("/obj/optional\n\ticon = 'icons/optional.dmi'\n", encoding="utf-8")
			dme = game_dir / "tgstation.dme"
			dme.write_text('#include "code/optional.dm"\n', encoding="utf-8")

			included = rsc_deploy.resource_inputs_sha256(game_dir)
			# Commenting a module out of the .dme removes its resources from the
			# compiled RSC; an unchanged name would publish a mismatched archive.
			dme.write_text('//#include "code/optional.dm"\n', encoding="utf-8")
			self.assertNotEqual(rsc_deploy.resource_inputs_sha256(game_dir), included)

			dme.write_text('#include "code/optional.dm"\n', encoding="utf-8")
			self.assertEqual(rsc_deploy.resource_inputs_sha256(game_dir), included)
			source.write_text(
				"#ifdef OPTIONAL_CONTENT\n/obj/optional\n\ticon = 'icons/optional.dmi'\n#endif\n",
				encoding="utf-8",
			)
			self.assertNotEqual(rsc_deploy.resource_inputs_sha256(game_dir), included)

	def test_resource_fingerprint_cache_reuses_clean_git_blobs(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			game_dir = Path(temporary_directory)
			(game_dir / "code").mkdir()
			(game_dir / "icons").mkdir()
			(game_dir / "code" / "feature.dm").write_text(
				"/obj/example\n\ticon = 'icons/example.dmi'\n", encoding="utf-8"
			)
			(game_dir / "icons" / "example.dmi").write_bytes(b"icon")
			subprocess.run(["git", "init", "-q", str(game_dir)], check=True)
			subprocess.run(["git", "-C", str(game_dir), "config", "user.email", "test@example.test"], check=True)
			subprocess.run(["git", "-C", str(game_dir), "config", "user.name", "RSC Test"], check=True)
			subprocess.run(["git", "-C", str(game_dir), "add", "."], check=True)
			subprocess.run(["git", "-C", str(game_dir), "commit", "-qm", "fixture"], check=True)
			cache_path = game_dir / ".rsc-cache.json"
			first = rsc_deploy.resource_inputs_sha256(game_dir, cache_path=cache_path)
			self.assertTrue(cache_path.is_file())
			with mock.patch.object(rsc_deploy, "_scan_resource_source", side_effect=AssertionError("cache miss")):
				with mock.patch.object(rsc_deploy, "sha256_file", side_effect=AssertionError("cache miss")):
					second = rsc_deploy.resource_inputs_sha256(game_dir, cache_path=cache_path)
			self.assertEqual(second, first)

	def test_windows_hooks_use_repository_python_bootstrap(self):
		hooks_dir = SCRIPT.parent.parent / "tgs4_scripts"
		for hook_name in ("PreCompile.bat", "PostCompile.bat"):
			hook = (hooks_dir / hook_name).read_text(encoding="utf-8")
			self.assertIn("bootstrap\\python.bat", hook)
			if hook_name != "PreCompile.bat":
				continue
			# Invoking another .bat without `call` hands control over for good: cmd
			# never comes back, so everything after it - including the rsc_deploy
			# prepare step which writes the deployment defines - silently never runs
			# and the DMB ships without external RSC URLs.
			self.assertIn("call tools\\build\\build", hook)

	def test_content_cleanup_protects_every_deployable_dmb_inventory(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			game_root = root / "Game"
			current_dir = game_root / "current" / "A"
			old_dir = game_root / "old" / "A"
			publish_dir = root / "publish"
			lobby_root = publish_dir / "lobby-media"
			asset_root = publish_dir / "browser-assets"
			inventory_root = asset_root / ".manifests"
			for directory in (current_dir, old_dir, lobby_root / "aa", asset_root / "bb", inventory_root):
				directory.mkdir(parents=True, exist_ok=True)

			(current_dir / "tgstation.dmb").write_bytes(b"current")
			(old_dir / "tgstation.dmb").write_bytes(b"old")
			current_manifest = {
				"archive_name": "Moon-Test-current.zip",
				"lobby_media_enabled": True,
				"browser_asset_webroot_enabled": True,
				"browser_asset_manifest": "current.txt",
			}
			old_manifest = {
				"archive_name": "Moon-Test-old.zip",
				"lobby_media_enabled": True,
				"lobby_media_files": ["aa/old.ogg"],
				"browser_asset_webroot_enabled": True,
				"browser_asset_manifest": "old.txt",
			}
			(current_dir / ".rsc-deploy.json").write_text(json.dumps(current_manifest), encoding="utf-8")
			(old_dir / ".rsc-deploy.json").write_text(json.dumps(old_manifest), encoding="utf-8")
			(inventory_root / "current.txt").write_text("bb/current.js\n", encoding="utf-8")
			(inventory_root / "old.txt").write_text("bb/old.js\n", encoding="utf-8")
			(inventory_root / "stale.txt").write_text("bb/stale.js\n", encoding="utf-8")

			protected_files = (
				lobby_root / "aa" / "current.ogg",
				lobby_root / "aa" / "old.ogg",
				asset_root / "bb" / "current.js",
				asset_root / "bb" / "old.js",
			)
			stale_files = (lobby_root / "aa" / "stale.ogg", asset_root / "bb" / "stale.js")
			for path in protected_files + stale_files:
				path.write_bytes(path.name.encode("ascii"))
			for path in protected_files + stale_files + tuple(inventory_root.glob("*.txt")):
				os.utime(path, (1, 1))

			settings = {
				"RSC_PRUNE_ENABLED": True,
				"RSC_DEPLOYMENT_ROOTS": [game_root],
				"RSC_PUBLISH_DIR": str(publish_dir),
				"RSC_LOBBY_MEDIA_SUBDIR": "lobby-media",
				"RSC_ASSET_WEBROOT_SUBDIR": "browser-assets",
				"RSC_PRUNE_GRACE_HOURS": 0,
			}
			removed = rsc_deploy.prune_content_stores(
				current_dir,
				settings,
				current_dir / ".rsc-deploy.json",
				["aa/current.ogg"],
			)
			self.assertEqual(removed, 3)
			for path in protected_files:
				self.assertTrue(path.is_file())
			for path in stale_files:
				self.assertFalse(path.exists())
			self.assertTrue((inventory_root / "current.txt").is_file())
			self.assertTrue((inventory_root / "old.txt").is_file())
			self.assertFalse((inventory_root / "stale.txt").exists())

	def test_invalid_rsc_mirror_url_is_rejected(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			settings_path = root / "rsc_deploy.env"
			settings_path.write_text(
				"RSC_PUBLIC_BASE_URL=https://download.example.test/rsc\n"
				"RSC_PUBLIC_MIRROR_BASE_URLS=ftp://mirror.example.test/rsc\n"
				"RSC_PUBLISH_DIR={}\n".format((root / "publish").as_posix()),
				encoding="utf-8",
			)
			with self.assertRaisesRegex(rsc_deploy.DeployError, "entry 1 must start"):
				rsc_deploy.load_settings(root, settings_path)

	def test_archive_names_are_namespaced_per_tgs_instance(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			settings = []
			for instance_name in ("main", "test"):
				config_path = root / instance_name / "Configuration" / "GameStaticFiles" / "config" / "rsc_deploy.env"
				config_path.parent.mkdir(parents=True)
				config_path.write_text(
					"RSC_PUBLIC_BASE_URL=https://download.example.test/rsc\n"
					"RSC_PUBLISH_DIR={}\n".format((root / "publish").as_posix()),
					encoding="utf-8",
				)
				settings.append(rsc_deploy.load_settings(root, config_path))
			resource_hash = "a" * 64
			self.assertNotEqual(
				rsc_deploy.archive_inputs_sha256(resource_hash, settings[0]),
				rsc_deploy.archive_inputs_sha256(resource_hash, settings[1]),
			)

	def test_legacy_alias_follows_the_newest_archive_and_survives_pruning(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			game_root = root / "Game"
			current_dir = game_root / "current" / "A"
			publish_dir = root / "publish"
			current_dir.mkdir(parents=True)
			publish_dir.mkdir()
			settings = {
				"RSC_PRUNE_ENABLED": True,
				"RSC_DEPLOYMENT_ROOTS": [game_root],
				"RSC_PUBLISH_DIR": str(publish_dir),
				"RSC_ARCHIVE_PREFIX": "Moon-Test",
				"RSC_DEPLOYMENT_NAMESPACE": "unit-test",
				"RSC_KEEP_UNREFERENCED": 0,
				"RSC_PRUNE_GRACE_HOURS": 0,
			}
			name_prefix = rsc_deploy.archive_name_prefix(settings)
			(current_dir / "tgstation.dmb").write_bytes(b"current")
			(current_dir / ".rsc-deploy.json").write_text(
				json.dumps({"archive_name": "{}-second.zip".format(name_prefix)}), encoding="utf-8"
			)
			first = publish_dir / "{}-first.zip".format(name_prefix)
			second = publish_dir / "{}-second.zip".format(name_prefix)
			first.write_bytes(b"first archive")
			second.write_bytes(b"second archive")

			alias = rsc_deploy.publish_legacy_alias(publish_dir, first, "Moon-Test.zip")
			self.assertEqual(alias, "Moon-Test.zip")
			alias_path = publish_dir / "Moon-Test.zip"
			self.assertEqual(alias_path.read_bytes(), b"first archive")
			# A later deployment repoints the fallback without touching the
			# archive the previous alias referenced.
			rsc_deploy.publish_legacy_alias(publish_dir, second, "Moon-Test.zip")
			self.assertEqual(alias_path.read_bytes(), b"second archive")
			self.assertEqual(first.read_bytes(), b"first archive")

			removed = rsc_deploy.prune_archives(current_dir, settings, second.name)
			self.assertEqual(removed, 1)
			self.assertFalse(first.exists())
			# Cleanup only owns the versioned names; the fallback must remain
			# readable even once its original archive is gone.
			self.assertEqual(alias_path.read_bytes(), b"second archive")

	def test_rejected_strict_publish_leaves_the_legacy_alias_untouched(self):
		"""The alias is activation state: a release refused by verification must not move it."""
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			game_dir = root / "Game" / "current" / "A"
			publish_dir = root / "publish"
			settings_path = root / "rsc_deploy.env"
			(game_dir / "code").mkdir(parents=True)
			(game_dir / "code" / "_compile_options.dm").write_text(
				"#define DEPLOYMENT_RSC_URLS null\n", encoding="utf-8"
			)
			(game_dir / "tgstation.dme").write_text(
				'#include "code\\_compile_options.dm"\n', encoding="utf-8"
			)
			(game_dir / "tgstation.rsc").write_bytes(dreammaker_rsc_fixture(1_720_000_100))
			(game_dir / "tgstation.dmb").write_bytes(b"compiled game")
			settings_path.write_text(
				"RSC_PUBLIC_BASE_URL=http://download.example.test/byond_rsc\n"
				"RSC_PUBLISH_DIR={}\n"
				"RSC_ARCHIVE_PREFIX=Moon-Test\n"
				"RSC_COMPRESSION_LEVEL=0\n"
				"RSC_MIN_FREE_BYTES=0\n"
				"RSC_PUBLISH_LOBBY_MEDIA=0\n"
				"RSC_ENABLE_ASSET_WEBROOT=0\n"
				"RSC_VERIFY_PUBLIC_URL=1\n"
				"RSC_REQUIRE_PUBLIC_VERIFICATION=1\n".format(publish_dir.as_posix()),
				encoding="utf-8",
			)
			common = argparse.Namespace(game_dir=str(game_dir), config=str(settings_path))
			with mock.patch.object(rsc_deploy, "probe_public_base_url", return_value=True):
				rsc_deploy.prepare(argparse.Namespace(revision="abcdef0123456789", **vars(common)))
			manifest = json.loads((game_dir / ".rsc-deploy.json").read_text(encoding="utf-8"))
			name_prefix = rsc_deploy.archive_name_prefix(rsc_deploy.load_settings(game_dir, settings_path))
			alias_path = publish_dir / "Moon-Test.zip"
			alias_path.write_bytes(b"previous fallback archive")

			with mock.patch.object(rsc_deploy, "verify_public_url", return_value=False):
				with self.assertRaisesRegex(rsc_deploy.DeployError, "refusing to activate"):
					rsc_deploy.publish(common)
			self.assertEqual(alias_path.read_bytes(), b"previous fallback archive")
			self.assertFalse((publish_dir / "{}-active.json".format(name_prefix)).exists())
			self.assertFalse((publish_dir / "{}-latest.json".format(name_prefix)).exists())

			# The same release passing verification must still repoint the alias.
			with mock.patch.object(rsc_deploy, "verify_public_url", return_value=True):
				rsc_deploy.publish(common)
			self.assertEqual(
				alias_path.read_bytes(),
				(publish_dir / manifest["archive_name"]).read_bytes(),
			)
			self.assertTrue((publish_dir / "{}-active.json".format(name_prefix)).exists())

	def test_cleanup_honours_the_grace_period_and_the_keep_count(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			game_root = root / "Game"
			current_dir = game_root / "current" / "A"
			publish_dir = root / "publish"
			current_dir.mkdir(parents=True)
			publish_dir.mkdir()
			settings = {
				"RSC_PRUNE_ENABLED": True,
				"RSC_DEPLOYMENT_ROOTS": [game_root],
				"RSC_PUBLISH_DIR": str(publish_dir),
				"RSC_ARCHIVE_PREFIX": "Moon-Test",
				"RSC_DEPLOYMENT_NAMESPACE": "unit-test",
				"RSC_KEEP_UNREFERENCED": 1,
				"RSC_PRUNE_GRACE_HOURS": 24,
			}
			name_prefix = rsc_deploy.archive_name_prefix(settings)
			current = "{}-current.zip".format(name_prefix)
			(current_dir / "tgstation.dmb").write_bytes(b"current")
			(current_dir / ".rsc-deploy.json").write_text(
				json.dumps({"archive_name": current}), encoding="utf-8"
			)
			(publish_dir / current).write_bytes(b"in use")
			stale = []
			for index in range(3):
				archive = publish_dir / "{}-stale{}.zip".format(name_prefix, index)
				archive.write_bytes(b"unreferenced")
				stale.append(archive)

			# Freshly written archives are inside the grace window: a deployment
			# rolled back minutes later must still find its archive.
			self.assertEqual(rsc_deploy.prune_archives(current_dir, settings, current), 0)
			for archive in stale:
				self.assertTrue(archive.exists())

			long_ago = 1_000_000
			for index, archive in enumerate(stale):
				os.utime(archive, (long_ago + index, long_ago + index))
			self.assertEqual(rsc_deploy.prune_archives(current_dir, settings, current), 2)
			# The newest unreferenced archive is the one kept by RSC_KEEP_UNREFERENCED.
			self.assertFalse(stale[0].exists())
			self.assertFalse(stale[1].exists())
			self.assertTrue(stale[2].exists())
			self.assertTrue((publish_dir / current).exists())

	@unittest.skipUnless(os.name == "posix", "file modes are only meaningful on POSIX hosts")
	def test_published_files_and_directories_are_readable_by_the_web_server(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			source = root / "source.ogg"
			source.write_bytes(b"lobby music")
			nested = root / "publish" / "lobby-media" / "ab"
			previous_umask = os.umask(0o077)
			try:
				rsc_deploy.atomic_copy(source, nested / "content.ogg")
				rsc_deploy.atomic_write(root / "publish" / "manifest.json", "{}\n")
			finally:
				os.umask(previous_umask)
			self.assertEqual((nested / "content.ogg").stat().st_mode & 0o044, 0o044)
			self.assertEqual((root / "publish" / "manifest.json").stat().st_mode & 0o044, 0o044)
			for directory in (root / "publish", root / "publish" / "lobby-media", nested):
				self.assertEqual(directory.stat().st_mode & 0o055, 0o055)

	def test_legacy_alias_may_not_shadow_a_managed_archive_name(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			settings_path = root / "rsc_deploy.env"
			settings_path.write_text(
				"RSC_PUBLIC_BASE_URL=https://download.example.test/rsc\n"
				"RSC_PUBLISH_DIR={}\n"
				"RSC_ARCHIVE_PREFIX=Moon-Test\n"
				"RSC_LEGACY_ALIAS_NAME=Moon-Test-abc.zip\n".format((root / "publish").as_posix()),
				encoding="utf-8",
			)
			with self.assertRaisesRegex(rsc_deploy.DeployError, "must not collide"):
				rsc_deploy.load_settings(root, settings_path)

	def test_pruning_fails_closed_when_a_dmb_has_no_manifest(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			game_root = root / "Game"
			current_dir = game_root / "current" / "A"
			unknown_dir = game_root / "unknown" / "A"
			publish_dir = root / "publish"
			current_dir.mkdir(parents=True)
			unknown_dir.mkdir(parents=True)
			publish_dir.mkdir()
			(current_dir / "tgstation.dmb").write_bytes(b"current")
			(current_dir / ".rsc-deploy.json").write_text(
				json.dumps({"archive_name": "Moon-Test-current.zip"}), encoding="utf-8"
			)
			(unknown_dir / "unknown.dmb").write_bytes(b"unknown")
			candidate = publish_dir / "Moon-Test-unreferenced.zip"
			candidate.write_bytes(b"keep me")

			settings = {
				"RSC_PRUNE_ENABLED": True,
				"RSC_DEPLOYMENT_ROOTS": [game_root],
				"RSC_PUBLISH_DIR": str(publish_dir),
				"RSC_ARCHIVE_PREFIX": "Moon-Test",
				"RSC_KEEP_UNREFERENCED": 0,
				"RSC_PRUNE_GRACE_HOURS": 0,
			}
			removed = rsc_deploy.prune_archives(current_dir, settings, "Moon-Test-current.zip")
			self.assertEqual(removed, 0)
			self.assertEqual(candidate.read_bytes(), b"keep me")

	def _prepare_fixture(self, root, publish_dir=None, extra_settings=""):
		"""Build the smallest tree prepare accepts: a game directory and a host config."""
		game_dir = root / "Game" / "current" / "A"
		config_root = root / "Configuration" / "GameStaticFiles" / "config"
		(game_dir / "code").mkdir(parents=True)
		(config_root / "entries").mkdir(parents=True)
		(config_root / "entries" / "resources.txt").write_text("# browser assets\n", encoding="utf-8")
		(game_dir / "tgstation.dme").write_text('#include "code\\_compile_options.dm"\n', encoding="utf-8")
		(game_dir / "tgstation.rsc").write_bytes(b"compiled resources")
		(game_dir / "tgstation.dmb").write_bytes(b"compiled game")
		settings_path = config_root / "rsc_deploy.env"
		settings_path.write_text(
			"RSC_PUBLIC_BASE_URL=http://download.example.test/byond_rsc\n"
			"RSC_PUBLISH_DIR={}\n"
			"RSC_ARCHIVE_PREFIX=Moon-Test\n"
			"RSC_COMPRESSION_LEVEL=0\n"
			"RSC_MIN_FREE_BYTES=0\n"
			"RSC_PRUNE_ENABLED=0\n"
			"RSC_PUBLISH_LOBBY_MEDIA=0\n"
			"RSC_VERIFY_PUBLIC_URL=0\n"
			"RSC_ENABLE_ASSET_WEBROOT=1\n".format((publish_dir or root / "publish").as_posix())
			+ extra_settings,
			encoding="utf-8",
		)
		return game_dir, settings_path

	@staticmethod
	def _prepare_arguments(game_dir, settings_path):
		return argparse.Namespace(game_dir=str(game_dir), revision="fixture", config=str(settings_path))

	def test_prepare_rejects_a_publish_directory_it_cannot_create(self):
		"""A typo in RSC_PUBLISH_DIR must cost a log line, not a whole compilation."""
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			blocker = root / "blocker"
			blocker.write_bytes(b"a file where a directory was configured")
			game_dir, settings_path = self._prepare_fixture(root, publish_dir=blocker / "byond_rsc")
			with self.assertRaisesRegex(rsc_deploy.DeployError, "cannot prepare the publish directory"):
				rsc_deploy.prepare(self._prepare_arguments(game_dir, settings_path))
			self.assertFalse((game_dir / ".rsc-deploy.json").exists())

	def test_prepare_fails_before_compilation_when_the_filesystem_is_full(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			game_dir, settings_path = self._prepare_fixture(
				root, extra_settings="RSC_MIN_FREE_BYTES=1073741824\n"
			)
			with mock.patch.object(rsc_deploy.shutil, "disk_usage", return_value=mock.Mock(free=1024)):
				with self.assertRaisesRegex(rsc_deploy.DeployError, "free bytes, but"):
					rsc_deploy.prepare(self._prepare_arguments(game_dir, settings_path))
			self.assertFalse((game_dir / ".rsc-deploy.json").exists())

	def test_prepare_requires_the_managed_resources_config(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			game_dir, settings_path = self._prepare_fixture(root)
			(settings_path.parent / "entries" / "resources.txt").unlink()
			with self.assertRaisesRegex(rsc_deploy.DeployError, "cannot configure webroot asset transport"):
				rsc_deploy.prepare(self._prepare_arguments(game_dir, settings_path))

	def test_latest_report_is_namespaced_per_tgs_instance(self):
		"""Two instances sharing one publish directory must not overwrite each other."""
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			publish_dir = root / "publish"
			for instance_name in ("main", "test"):
				game_dir, settings_path = self._prepare_fixture(root / instance_name, publish_dir=publish_dir)
				common = ["--game-dir", str(game_dir), "--config", str(settings_path)]
				subprocess.run([sys.executable, str(SCRIPT), "prepare", *common], check=True)
				subprocess.run([sys.executable, str(SCRIPT), "publish", *common], check=True)
			reports = sorted(path.name for path in publish_dir.glob("*-latest.json"))
			self.assertEqual(len(reports), 2, reports)
			for name in reports:
				self.assertTrue(name.startswith("Moon-Test-"), name)
			self.assertNotEqual(
				json.loads((publish_dir / reports[0]).read_text(encoding="utf-8"))["archive_name"],
				json.loads((publish_dir / reports[1]).read_text(encoding="utf-8"))["archive_name"],
			)

	def test_public_url_verification_survives_a_web_server_reload(self):
		class Response:
			status = 200
			headers = {"Content-Length": "7"}

			def __enter__(self):
				return self

			def __exit__(self, *arguments):
				return False

		attempts = []

		def flaky(request, timeout=None):
			attempts.append(timeout)
			if len(attempts) < 3:
				raise urllib.error.URLError("connection refused")
			return Response()

		with mock.patch.object(rsc_deploy.time, "sleep") as sleep:
			with mock.patch.object(rsc_deploy.urllib.request, "urlopen", side_effect=flaky):
				self.assertTrue(
					rsc_deploy.verify_public_url("http://download.example.test/a.zip", expected_size=7)
				)
		self.assertEqual(len(attempts), 3)
		self.assertEqual([call.args[0] for call in sleep.call_args_list], [1, 3])

	def test_public_url_verification_gives_up_with_a_warning(self):
		with mock.patch.object(rsc_deploy.time, "sleep"):
			with mock.patch.object(
				rsc_deploy.urllib.request, "urlopen", side_effect=urllib.error.URLError("down")
			) as urlopen:
				self.assertFalse(rsc_deploy.verify_public_url("http://download.example.test/a.zip"))
		self.assertEqual(urlopen.call_count, 3)

	def test_public_url_verification_does_not_retry_a_rejected_request(self):
		denied = urllib.error.HTTPError("http://download.example.test/a.zip", 403, "Forbidden", None, None)
		with mock.patch.object(rsc_deploy.time, "sleep") as sleep:
			with mock.patch.object(rsc_deploy.urllib.request, "urlopen", side_effect=denied) as urlopen:
				self.assertFalse(rsc_deploy.verify_public_url("http://download.example.test/a.zip"))
		self.assertEqual(urlopen.call_count, 1)
		self.assertFalse(sleep.called)

	def test_public_url_verification_checks_every_client_mirror(self):
		urls = [
			"http://download.example.test/a.zip",
			"https://mirror-one.example.test/a.zip",
			"https://mirror-two.example.test/a.zip",
		]
		with mock.patch.object(rsc_deploy, "verify_public_url", side_effect=[True, False, True]) as verify:
			verdicts = rsc_deploy.verify_public_urls(urls, expected_size=42)
		self.assertEqual(verdicts, dict(zip(urls, [True, False, True])))
		self.assertEqual(
			verify.call_args_list,
			[mock.call(url, expected_size=42) for url in urls],
		)

	def test_component_verification_checks_the_same_file_on_every_frontend(self):
		settings = {
			"RSC_PUBLIC_BASE_URLS": [
				"https://primary.example.test/rsc",
				"https://mirror.example.test/rsc",
			]
		}
		with mock.patch.object(rsc_deploy, "verify_public_urls", return_value={"ok": True}) as verify:
			result = rsc_deploy.verify_component_representative(
				settings, "browser-assets", "ab/asset.hash.js", 123
			)
		self.assertEqual(result, {"ok": True})
		verify.assert_called_once_with(
			[
				"https://primary.example.test/rsc/browser-assets/ab/asset.hash.js",
				"https://mirror.example.test/rsc/browser-assets/ab/asset.hash.js",
			],
			expected_size=123,
		)

	def test_the_base_url_probe_accepts_any_http_answer(self):
		"""A disabled directory listing is the normal answer, not a broken deployment."""
		denied = urllib.error.HTTPError("http://download.example.test/", 403, "Forbidden", None, None)
		with mock.patch.object(rsc_deploy.time, "sleep") as sleep:
			with mock.patch.object(rsc_deploy.urllib.request, "urlopen", side_effect=denied) as urlopen:
				self.assertTrue(rsc_deploy.probe_public_base_url("http://download.example.test/"))
		self.assertEqual(urlopen.call_count, 1)
		self.assertFalse(sleep.called)

	def test_the_base_url_probe_warns_when_nothing_answers(self):
		with mock.patch.object(rsc_deploy.time, "sleep"):
			with mock.patch.object(
				rsc_deploy.urllib.request, "urlopen", side_effect=urllib.error.URLError("down")
			) as urlopen:
				self.assertFalse(rsc_deploy.probe_public_base_url("http://download.example.test/"))
		self.assertEqual(urlopen.call_count, 3)

	def test_a_hung_git_is_reported_instead_of_hanging_the_deployment(self):
		timeout = subprocess.TimeoutExpired("git", rsc_deploy.GIT_TIMEOUT_SECONDS)
		with mock.patch.object(rsc_deploy.subprocess, "run", side_effect=timeout):
			# The revision is only a label and TGS already supplied one, so a hung git
			# warns and falls back instead of failing the build.
			with mock.patch.object(rsc_deploy, "log") as logged:
				self.assertEqual(rsc_deploy.git_revision(Path("."), "abcdef"), "abcdef")
			self.assertTrue(
				any("did not finish within" in str(call) for call in logged.call_args_list),
				logged.call_args_list,
			)
			# The fingerprint stays fatal: there a hung git silently shrinks the set of
			# hashed files and hands out an archive name which does not match its contents.
			with self.assertRaisesRegex(rsc_deploy.DeployError, "did not finish within"):
				rsc_deploy._git_file_identities(Path("."))

	def test_a_missing_compiler_version_warns_instead_of_vanishing(self):
		"""A compiler silently dropped from the fingerprint is a deterministic dead end.

		validate_archive rejects an archive built by another BYOND version, and the
		archive name never moves to make room for it, so the deployment fails the same
		way on every retry with nothing in the log pointing at .tgs.yml.
		"""
		with tempfile.TemporaryDirectory() as temporary_directory:
			game_dir = Path(temporary_directory)
			(game_dir / rsc_deploy.TGS_CONFIG_NAME).write_text(
				"version: 4\nscript_paths:\n  - tools/tgs4_scripts\n", encoding="utf-8"
			)
			with mock.patch.object(rsc_deploy, "log") as logged:
				self.assertEqual(rsc_deploy.compiler_build_inputs(game_dir), [])
			self.assertTrue(
				any("byond:" in str(call) for call in logged.call_args_list),
				logged.call_args_list,
			)

	def test_a_present_compiler_version_is_fingerprinted_silently(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			game_dir = Path(temporary_directory)
			(game_dir / rsc_deploy.TGS_CONFIG_NAME).write_text(
				"version: 4\nbyond: \"516.1663\"\n", encoding="utf-8"
			)
			with mock.patch.object(rsc_deploy, "log") as logged:
				self.assertEqual(rsc_deploy.compiler_build_inputs(game_dir), [("byond-version", "516.1663")])
			self.assertFalse(logged.called, logged.call_args_list)

	def test_a_checkout_without_a_tgs_config_stays_quiet(self):
		"""No .tgs.yml at all is what a local checkout looks like - nothing to warn about."""
		with tempfile.TemporaryDirectory() as temporary_directory:
			with mock.patch.object(rsc_deploy, "log") as logged:
				self.assertEqual(rsc_deploy.compiler_build_inputs(Path(temporary_directory)), [])
			self.assertFalse(logged.called, logged.call_args_list)

	def test_the_preflight_probe_does_not_retry(self):
		"""Preflight runs before a 15-25 minute compile; retries only add dead waiting."""
		with mock.patch.object(rsc_deploy, "validate_writable_directory", return_value=1024):
			with mock.patch.object(rsc_deploy, "require_asset_config"):
				with mock.patch.object(rsc_deploy.time, "sleep") as sleep:
					with mock.patch.object(
						rsc_deploy.urllib.request, "urlopen", side_effect=urllib.error.URLError("down")
					) as urlopen:
						rsc_deploy.preflight_publish_target({
							"RSC_PUBLISH_DIR": ".",
							"RSC_MIN_FREE_BYTES": 0,
							"RSC_VERIFY_PUBLIC_URL": True,
							"RSC_PUBLIC_BASE_URL": "http://download.example.test/byond_rsc",
						})
		self.assertEqual(urlopen.call_count, 1)
		self.assertFalse(sleep.called)

	def test_abandoned_legacy_alias_temporaries_are_swept(self):
		with tempfile.TemporaryDirectory() as temporary_directory:
			root = Path(temporary_directory)
			game_root = root / "Game"
			current_dir = game_root / "current" / "A"
			publish_dir = root / "publish"
			current_dir.mkdir(parents=True)
			publish_dir.mkdir()
			settings = {
				"RSC_PRUNE_ENABLED": True,
				"RSC_DEPLOYMENT_ROOTS": [game_root],
				"RSC_PUBLISH_DIR": str(publish_dir),
				"RSC_ARCHIVE_PREFIX": "Moon-Test",
				"RSC_DEPLOYMENT_NAMESPACE": "unit-test",
				"RSC_LEGACY_ALIAS_NAME": "Moon-Test.zip",
				"RSC_KEEP_UNREFERENCED": 0,
				"RSC_PRUNE_GRACE_HOURS": 24,
			}
			name_prefix = rsc_deploy.archive_name_prefix(settings)
			current = "{}-current.zip".format(name_prefix)
			(current_dir / "tgstation.dmb").write_bytes(b"current")
			(current_dir / ".rsc-deploy.json").write_text(
				json.dumps({"archive_name": current}), encoding="utf-8"
			)
			(publish_dir / current).write_bytes(b"in use")
			(publish_dir / "Moon-Test.zip").write_bytes(b"fallback alias")
			abandoned_alias = publish_dir / ".Moon-Test.zip-abandoned.tmp"
			abandoned_archive = publish_dir / ".{}-abandoned.tmp".format(name_prefix)
			in_flight_alias = publish_dir / ".Moon-Test.zip-inflight.tmp"
			for path in (abandoned_alias, abandoned_archive, in_flight_alias):
				path.write_bytes(b"partial write")
			long_ago = 1_000_000
			for path in (abandoned_alias, abandoned_archive):
				os.utime(path, (long_ago, long_ago))

			self.assertEqual(rsc_deploy.prune_archives(current_dir, settings, current), 2)
			self.assertFalse(abandoned_alias.exists())
			self.assertFalse(abandoned_archive.exists())
			# A concurrent deployment's temporary is inside the grace window.
			self.assertTrue(in_flight_alias.is_file())
			self.assertEqual((publish_dir / "Moon-Test.zip").read_bytes(), b"fallback alias")

	def test_deployment_tooling_does_not_invalidate_published_archives(self):
		"""Only what DreamMaker embeds, plus the compiler, may move the archive name."""
		with tempfile.TemporaryDirectory() as temporary_directory:
			game_dir = Path(temporary_directory)
			(game_dir / "code").mkdir()
			(game_dir / "icons").mkdir()
			(game_dir / "icons" / "example.dmi").write_bytes(b"icon")
			(game_dir / "code" / "feature.dm").write_text(
				"/obj/example\n\ticon = 'icons/example.dmi'\n", encoding="utf-8"
			)
			tgs_config = game_dir / ".tgs.yml"
			tgs_config.write_text(
				"version: 1\n"
				"byond: \"516.1684\"\n"
				"windows_scripts:\n"
				"  PreCompile.bat: tools/tgs4_scripts/PreCompile.bat\n",
				encoding="utf-8",
			)

			baseline = rsc_deploy.resource_inputs_sha256(game_dir)
			# Rewiring or adding a deployment hook changes nothing a client downloads.
			tgs_config.write_text(
				"version: 1\n"
				"byond: \"516.1684\"\n"
				"windows_scripts:\n"
				"  PreCompile.bat: tools/tgs4_scripts/PreCompile.bat\n"
				"  PostCompile.bat: tools/tgs4_scripts/PostCompile.bat\n"
				"security: Trusted\n",
				encoding="utf-8",
			)
			self.assertEqual(rsc_deploy.resource_inputs_sha256(game_dir), baseline)

			# A different compiler may lay the resource container out differently.
			tgs_config.write_text(
				"version: 1\n"
				"byond: \"517.1000\"\n"
				"windows_scripts:\n"
				"  PreCompile.bat: tools/tgs4_scripts/PreCompile.bat\n"
				"  PostCompile.bat: tools/tgs4_scripts/PostCompile.bat\n"
				"security: Trusted\n",
				encoding="utf-8",
			)
			self.assertNotEqual(rsc_deploy.resource_inputs_sha256(game_dir), baseline)


if __name__ == "__main__":
	unittest.main()
