#!/bin/bash

# TGS PreCompile hook.
# $1 - the deployment game directory (a fresh copy of the repository)
# $2 - the origin commit sha TGS is deploying
#
# REPO MAINTAINERS: KEEP CHANGES TO THIS IN SYNC WITH /tools/LinuxOneShot/SetupProgram/PreCompile.sh
set -e
set -x

game_dir="${1:?TGS did not provide the game directory}"
revision="${2:-}"
event_scripts_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

#load dep exports
#need to switch to game dir for Dockerfile weirdness
original_dir=$PWD
cd "$game_dir"
. dependencies.sh
cd "$original_dir"

#find out what we have (+e is important for this)
set +e
has_sudo="$(command -v sudo)"
has_ytdlp="$(command -v yt-dlp)"
has_pip3="$(command -v pip3)"
set -e

if [ -x "$has_sudo" ] && [ "$(id -u)" -ne 0 ]; then
	as_root() { sudo "$@"; }
else
	as_root() { "$@"; }
fi

# apt-get update is only worth its latency when something is actually missing,
# so package installation is driven by dpkg state instead of running every build.
apt_index_refreshed=0
refresh_apt_index() {
	if [ "$apt_index_refreshed" -eq 0 ]; then
		as_root apt-get update
		apt_index_refreshed=1
	fi
}

package_installed() {
	dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "^install ok installed$"
}

install_packages() {
	missing=""
	for package in "$@"; do
		if ! package_installed "$package"; then
			missing="$missing $package"
		fi
	done
	if [ -n "$missing" ]; then
		echo "Installing apt dependencies:$missing"
		refresh_apt_index
		# shellcheck disable=SC2086
		as_root apt-get install -y $missing
	fi
}

if ! dpkg --print-foreign-architectures | grep -qx "i386"; then
	echo "Enabling the i386 architecture for the 32-bit rust-g build..."
	as_root dpkg --add-architecture i386
	refresh_apt_index
fi

install_packages git grep curl python3 build-essential pkg-config lib32z1 \
	g++-multilib libc6-i386 libstdc++6:i386 libssl-dev libssl-dev:i386

# Debian/Ubuntu releases disagree on the 32-bit OpenSSL runtime package name.
if ! package_installed libssl3:i386 && ! package_installed libssl1.1:i386; then
	refresh_apt_index
	if apt-cache show libssl3:i386 > /dev/null 2>&1; then
		install_packages libssl3:i386
	elif apt-cache show libssl1.1:i386 > /dev/null 2>&1; then
		install_packages libssl1.1:i386
	else
		echo "Warning: no libssl runtime package for i386 is available; relying on libssl-dev:i386"
	fi
fi

# install cargo if needed
set +e
has_cargo="$(command -v cargo)"
set -e
if ! [ -x "$has_cargo" ] && [ -x "$HOME/.cargo/bin/cargo" ]; then
	. "$HOME/.cargo/env"
	has_cargo="$(command -v cargo)"
fi
if ! [ -x "$has_cargo" ]; then
	echo "Installing rust..."
	curl https://sh.rustup.rs -sSf | sh -s -- -y
	if [ -f "$HOME/.cargo/env" ]; then
		. "$HOME/.cargo/env"
	fi
fi
# rustup is normally installed beside cargo but is not always on PATH.
export PATH="$HOME/.cargo/bin:/usr/local/.cargo/bin:$PATH"

# update rust-g
if [ ! -d "rust-g" ]; then
	echo "Cloning rust-g..."
	git clone https://github.com/tgstation/rust-g
	cd rust-g
else
	echo "Fetching rust-g..."
	cd rust-g
	git fetch --tags --force
fi
rustup target add i686-unknown-linux-gnu

echo "Deploying rust-g..."
git checkout --force "$RUST_G_VERSION"
env PKG_CONFIG_ALLOW_CROSS=1 cargo build --release --target=i686-unknown-linux-gnu
mv target/i686-unknown-linux-gnu/release/librust_g.so "$game_dir/librust_g.so"
cd "$original_dir"

# install or update yt-dlp when not present, or if it is present with pip3,
# which we assume was used to install it. A failure here only disables the
# admin web sound verb, so it must never fail the deployment.
set +e
if ! [ -x "$has_ytdlp" ]; then
	echo "Installing yt-dlp..."
	if apt-cache show yt-dlp > /dev/null 2>&1; then
		install_packages yt-dlp
	else
		install_packages python3-pip
		pip3 install yt-dlp || pip3 install yt-dlp --break-system-packages
	fi
elif [ -x "$has_pip3" ]; then
	echo "Ensuring yt-dlp is up-to-date with pip3..."
	pip3 install yt-dlp -U || pip3 install yt-dlp -U --break-system-packages
fi
set -e

# compile tgui
echo "Compiling tgui..."
cd "$game_dir"
chmod +x tools/bootstrap/node  # Workaround for https://github.com/tgstation/tgstation-server/issues/1167
env TG_BOOTSTRAP_CACHE="$original_dir" TG_BOOTSTRAP_NODE_LINUX=1 CBT_BUILD_MODE="TGS" tools/bootstrap/node tools/build/build.js

# Generate a content-addressed external RSC URL before DreamMaker runs.
# code/_compile_options.dm includes the file this writes for every TGS build, so
# a failure here has to stop the deployment instead of producing a DMB whose
# clients would download every resource through DreamDaemon.
# PostCompile publishes the matching archive and fails the deployment if it cannot.
python3 tools/rsc_deploy/rsc_deploy.py prepare \
	--game-dir "$game_dir" \
	--revision "$revision" \
	--config "$event_scripts_dir/../GameStaticFiles/config/rsc_deploy.env"
