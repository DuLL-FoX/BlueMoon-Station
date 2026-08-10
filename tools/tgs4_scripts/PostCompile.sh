#!/bin/sh

# TGS PostCompile hook.
# $1 - the deployment game directory
#
# Publishes the archive whose URL PreCompile embedded into this DMB. A non-zero
# exit fails the deployment on purpose: the DMB must never go live before the
# resources its clients were told to download are available.
set -eu

game_dir="${1:?TGS did not provide the game directory}"
event_scripts_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

if ! command -v python3 > /dev/null 2>&1; then
	echo "python3 is required to publish the external RSC archive" >&2
	exit 1
fi

python3 "$game_dir/tools/rsc_deploy/rsc_deploy.py" publish \
	--game-dir "$game_dir" \
	--config "$event_scripts_dir/../GameStaticFiles/config/rsc_deploy.env"
