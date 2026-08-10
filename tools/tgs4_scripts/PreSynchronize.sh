#!/bin/sh

# TGS PreSynchronize hook.
# $1 - the repository directory, not the deployment game directory
#
# Compiles the loose YAML changelogs in html/changelogs into the monthly
# archive files. GitHub Actions normally does this first (see
# .github/workflows/compile_changelogs.yml), so this is a safety net for
# entries which reached the deployment before that workflow ran; it commits
# nothing when there is nothing to compile.
#
# TGS hard-resets the repository and drops untracked files immediately after
# this hook, so only a commit survives it; TGS performs the push itself. The
# virtual environment below therefore lives beside this script rather than in
# the repository.
#
# A changelog is never worth failing a deployment over, so every failure path
# here warns and exits 0.
set -eu

repo_dir="${1:-$PWD}"
event_scripts_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
venv_dir="$event_scripts_dir/.changelog-venv"

warn() {
	echo "[changelog] warning: $*" >&2
}

# The generator needs PyYAML and nothing else, so any interpreter which already
# has it avoids touching apt or pip. Modern Debian/Ubuntu refuse `pip install`
# outside a virtual environment, which is why the fallback below builds one.
find_python() {
	for candidate in "$venv_dir/bin/python" python3 python; do
		if [ "$candidate" = "$venv_dir/bin/python" ]; then
			[ -x "$candidate" ] || continue
		else
			command -v "$candidate" > /dev/null 2>&1 || continue
		fi
		if "$candidate" -c "import yaml" > /dev/null 2>&1; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

create_venv() {
	command -v python3 > /dev/null 2>&1 || return 1
	rm -rf "$venv_dir"
	python3 -m venv "$venv_dir" || return 1
	"$venv_dir/bin/python" -m pip install --upgrade pip || return 1
	"$venv_dir/bin/python" -m pip install PyYAML || return 1
	return 0
}

compile_changelogs() {
	cd "$repo_dir"
	if [ ! -f tools/ss13_genchangelog.py ] || [ ! -d html/changelogs ]; then
		warn "tools/ss13_genchangelog.py or html/changelogs is missing in $repo_dir"
		return 1
	fi

	python_exe="$(find_python || true)"
	if [ -z "$python_exe" ]; then
		echo "[changelog] preparing the changelog virtual environment..."
		if ! create_venv; then
			warn "could not provide a Python with PyYAML; install python3-venv or python3-yaml"
			return 1
		fi
		python_exe="$(find_python || true)"
		if [ -z "$python_exe" ]; then
			warn "the changelog virtual environment does not provide PyYAML"
			return 1
		fi
	fi

	echo "[changelog] compiling html/changelogs with $python_exe"
	"$python_exe" tools/ss13_genchangelog.py html/changelogs || return 1

	if [ -z "$(git status --porcelain -- html)" ]; then
		echo "[changelog] nothing to commit"
		return 0
	fi

	git add -- html
	# TGS does not guarantee a committer identity in the deployment repository.
	if [ -z "$(git config user.email || true)" ]; then
		set -- -c user.name="tgstation-server" -c user.email="tgs@localhost"
	else
		set --
	fi
	git "$@" commit -m "Automatic changelog compile, [ci skip]" || return 1
	echo "[changelog] committed the compiled changelogs"
	return 0
}

if ! compile_changelogs; then
	warn "the changelog step did not complete; continuing the deployment"
fi

exit 0
