param(
    $repo_path
)

# TGS PreSynchronize hook.
# $repo_path - the repository directory TGS is about to push back to origin.
#
# Compiles the loose YAML changelogs in html/changelogs into the monthly
# archive files. TGS hard-resets the repository right after this hook, so only
# what this script commits survives; TGS performs the push itself.
#
# A changelog is never worth failing a deployment over, so every failure path
# warns and exits 0.

if (!$repo_path) {
    $repo_path = $PWD
}
Set-Location $repo_path

$bootstrapPython = Join-Path $repo_path "tools\bootstrap\python.bat"
if (!(Test-Path $bootstrapPython)) {
    Write-Host "[changelog] warning: $bootstrapPython is missing; skipping"
    exit 0
}

# Keep the bootstrap cache outside the repository: TGS removes untracked files
# from it after this hook runs.
$env:TG_BOOTSTRAP_CACHE = $PSScriptRoot

Write-Host "[changelog] compiling html/changelogs..."
& $bootstrapPython "tools/ss13_genchangelog.py" "html/changelogs"
if (!$?) {
    Write-Host "[changelog] warning: ss13_genchangelog.py returned non-zero; continuing the deployment"
    exit 0
}

if (!(git status --porcelain -- html)) {
    Write-Host "[changelog] nothing to commit"
    exit 0
}

git add -- html
if (!$?) {
    Write-Host "[changelog] warning: git add returned non-zero; continuing the deployment"
    exit 0
}

# TGS configures a committer identity before this hook, but a manually created
# repository may not have one.
if (git config user.email) {
    git commit -m "Automatic changelog compile, [ci skip]"
} else {
    git -c user.name="tgstation-server" -c user.email="tgs@localhost" commit -m "Automatic changelog compile, [ci skip]"
}

exit 0
