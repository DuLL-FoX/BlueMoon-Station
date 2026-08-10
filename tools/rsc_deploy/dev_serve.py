#!/usr/bin/env python3
"""Serve a local publish directory the way the production frontend serves it.

Everything the composite transport does — external RSC archives, browser assets,
lobby media, the CDN probe — only runs when an HTTP server stands in front of the
publish directory. On a developer machine there is none, so the entire path is
normally exercised for the first time in production. This is that server: static
files, the CORS headers TGUI needs from another origin, and HEAD support for the
probes. Paradise ships the same idea as a small Rust binary in
tools/asset_server_rs; there is no reason for it to be more than a script.
"""

import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import sys


DEFAULT_PORT = 58715


class PublishDirectoryHandler(SimpleHTTPRequestHandler):
	"""Static handler with the headers the real frontend is configured to send."""

	def end_headers(self):
		# TGUI fetches browser-assets from another origin, so without these the
		# window opens with missing scripts, fonts and styles and nothing in the
		# server log explains why.
		self.send_header("Access-Control-Allow-Origin", "*")
		self.send_header("Vary", "Origin")
		# Content-addressed names only ever mean one thing, and a developer
		# reloading a window should not be served a stale copy of something the
		# next build replaced under the same non-versioned alias either.
		self.send_header("Cache-Control", "no-cache")
		super().end_headers()

	def do_OPTIONS(self):  # noqa: N802 - the base class spells its handlers this way
		self.send_response(204)
		self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
		self.send_header("Access-Control-Allow-Headers", "*")
		self.end_headers()

	def log_message(self, format, *args):  # noqa: A002 - base class signature
		# The default logs to stderr with a timestamp per line; keep it, but make
		# it obvious which process is talking when this runs beside DreamDaemon.
		sys.stderr.write("dev_serve: " + (format % args) + "\n")


def describe_configuration(root, base_url):
	"""Prints what has to be in the config for a build to use this server."""
	archives = sorted(path.name for path in root.glob("*.zip"))
	print("Serving {} at {}".format(root, base_url))
	print("")
	print("config/entries/resources.txt:")
	print("  ASSET_TRANSPORT webroot")
	print("  ASSET_CDN_URL {}/browser-assets/".format(base_url))
	print("  ASSET_CDN_WEBROOT {}".format((root / "browser-assets").as_posix() + "/"))
	if archives:
		print("  EXTERNAL_RSC_URLS {}/{}".format(base_url, archives[0]))
	else:
		print("  # No .zip in the publish directory yet: run rsc_deploy.py publish against it,")
		print("  # or point RSC_PUBLISH_DIR at this directory in your rsc_deploy.env first.")
	print("")
	print("ASSET_CDN_WEBROOT is a filesystem path read by DreamDaemon, ASSET_CDN_URL is")
	print("what clients are handed. They must describe the same directory.")
	print("")


def main():
	parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	parser.add_argument("root", nargs="?", default="data/rsc_publish", help="publish directory to serve")
	parser.add_argument("--port", type=int, default=DEFAULT_PORT)
	parser.add_argument("--host", default="127.0.0.1", help="bind address; 0.0.0.0 to reach it from another machine")
	parser.add_argument(
		"--public-host",
		default=None,
		help="host name to print in the config snippet, when clients reach this server under another name",
	)
	args = parser.parse_args()

	root = Path(args.root).resolve()
	if not root.is_dir():
		parser.error("{} is not a directory. Create it, or publish into it first.".format(root))
	for required in ("browser-assets", "lobby-media"):
		if not (root / required).is_dir():
			print("note: {} has no {}/ yet; that part of the deployment is simply not published.".format(root, required))

	base_url = "http://{}:{}".format(args.public_host or args.host, args.port)
	describe_configuration(root, base_url)

	handler = partial(PublishDirectoryHandler, directory=str(root))
	server = ThreadingHTTPServer((args.host, args.port), handler)
	print("Listening on {}:{}. Ctrl+C to stop.".format(args.host, args.port))
	try:
		server.serve_forever()
	except KeyboardInterrupt:
		print("")
	finally:
		server.server_close()
	return 0


if __name__ == "__main__":
	os.umask(0o022)
	sys.exit(main())
