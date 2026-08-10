# Content-addressed external RSC deployment

TGS runs `prepare` before DreamMaker and `publish` after a successful compile.
`prepare` fingerprints resource files, static DM resource references and
compile-time `#define`/`#undef` configuration, then embeds one or more
content-addressed URLs into that deployment's DMB. It writes the defines to the
ignored `.rsc-deployment.dm` and adds its include to the disposable TGS copy of
`tgstation.dme`, rather than changing tracked DM source. A small
`.rsc-input-cache.json` beside the persistent host config reuses Git blob
results, so unchanged `.dmm` files are not reparsed and unchanged resources are
not rehashed on every deployment.
`publish` creates and validates the matching ZIP in the nginx directory using a
temporary file and atomic rename. DreamMaker embeds compilation timestamps in
`tgstation.rsc`, so repeated builds from identical inputs are not bytewise
reproducible. An existing archive selected by the same input fingerprint is
therefore reused when its uncompressed RSC size matches; both SHA-256 digests
are recorded for diagnostics. A size mismatch catches the normal add/remove
case and fails the deployment instead of reusing an archive selected by an
unexpected stale fingerprint. Normal conditional-build variants get distinct
names before compilation because their compiler definitions participate in the
fingerprint. A publish failure fails the TGS compile, so a DMB can never go live
before its archive is available.

The same PostCompile transaction publishes the build-owned browser files and
lobby media, writes an immutable `.releases/<release-id>.json` contract for all
three components, and only then atomically replaces
`<prefix>-<namespace>-active.json`. The mutable pointer is the activation point;
an incomplete publication can never advertise itself as the active release.

## Who writes `.rsc-deployment.dm`

Its contents and DME include belong to `rsc_deploy.py prepare`: real deployment
URLs when the host config is present, a one-line disabled stub when it is not.
This keeps `tools/build/build.bat dm -DTGS` valid in a clean checkout. Because an
existing TGS instance keeps running the `EventScripts` copies it was set up with,
an instance carrying an older `PreCompile` hook simply compiles without the
generated include and uses `EXTERNAL_RSC_URLS`; the current hook inserts the
include before DreamMaker starts.
`tools/LinuxOneShot` does not build in TGS mode and keeps its own stub fallback
for images without `python3`.

The same publish step copies lobby backgrounds and lobby music to
content-addressed files below `lobby-media/`. It writes
`config/lobby_media.json`, which lets the lobby use direct HTTP URLs instead of
adding these files to BYOND's dynamic resource cache. It also configures the
built-in webroot transport below `browser-assets/`, moving TGUI, fonts and other
registered browser assets away from DreamDaemon. The tracked
`browser_assets.json` is the build-time boundary: listed static files are copied
by PostCompile using the exact paths the DM transport derives. Assets generated
only at runtime, including uncached spritesheets, are routed individually through
`browse_rsc` instead of writing into the public directory.

## One-time host setup

1. Copy `config/rsc_deploy.env.example` to the instance's persistent
   `Configuration/GameStaticFiles/config/rsc_deploy.env`.
2. Change `RSC_PUBLISH_DIR` to the nginx directory behind
   `RSC_PUBLIC_BASE_URL`.
3. Grant the account which runs the TGS hooks write access to that directory,
   and grant DreamDaemon read-only access. Ensure the filesystem has at least
   `RSC_MIN_FREE_BYTES` available after publication. PreCompile probes the
   directory before DreamMaker starts, so a misconfigured path costs a log line
   instead of a whole compilation. PostCompile repeats the write probe. At
   runtime the composite transport only checks immutable files: a missing file
   falls back to BYOND for that asset (or its complete namespace), while an
   endpoint-wide failure can still switch the whole transport to BYOND.
4. For an existing TGS instance, replace the matching `PreCompile` and
   `PostCompile` scripts (`.sh` on Linux, `.bat` on Windows) in
   `Configuration/EventScripts`. New instances receive both scripts from
   `.tgs.yml`. The Windows hooks use `tools/bootstrap/python.bat`, which installs
   the repository's pinned portable Python on first use; no system Python in
   `PATH` is required.

## Trying the whole thing locally

None of this runs without an HTTP server in front of the publish directory, so a
plain checkout exercises the composite transport, the archive URL and both probes
for the first time in production. `dev_serve.py` is that server:

```sh
python3 tools/rsc_deploy/dev_serve.py data/rsc_publish
```

It serves a directory with the CORS headers TGUI needs from another origin and
answers HEAD, which is what the deployment verification and the CDN probe use. It
prints the `ASSET_TRANSPORT`, `ASSET_CDN_URL`, `ASSET_CDN_WEBROOT` and
`EXTERNAL_RSC_URLS` lines for the directory it was given; put them in
`config/entries/resources.txt` and the local server behaves like the real
frontend. To fill that directory, point `RSC_PUBLISH_DIR` at it in a local
`rsc_deploy.env` and run the normal `publish` step.

It is a development tool: single process, no range requests, no access control.
Do not put it in front of players.

## CORS for browser assets

The `browser-assets/` files are fetched by TGUI from a different origin. That
HTTP location must provide CORS headers or TGUI can open with missing scripts,
fonts, images, or styles. For nginx, a minimal location is:

```nginx
location /byond_rsc/browser-assets/ {
    alias /var/www/byond_rsc/browser-assets/;
    add_header Access-Control-Allow-Origin "*" always;
    add_header Vary "Origin" always;
}
```

Adjust both paths to match `RSC_PUBLIC_BASE_URL` and `RSC_PUBLISH_DIR`. Lobby
backgrounds and music use normal `<img>` and `<audio>` loading, so their
`lobby-media/` location does not need CORS for playback. The RSC ZIP itself is
downloaded by BYOND, not by the browser, so it does not need browser CORS headers
either.

Adding them to it anyway buys one thing: the client probe asks the browser to
check the archive address, and without CORS the browser only tells it whether the
host answered at all. With `Access-Control-Allow-Origin` on that location the same
probe reports the real HTTP status, so a published archive which is missing or
returns 403 becomes visible from the client side too, not only from the server's.

With webroot enabled, TGUI bundles, the stat browser, tooltip HTML and their
static dependencies are loaded from `browser-assets/`. DreamDaemon still sends
live UI state, chat messages and tooltip content; only immutable files belong
on the CDN. The legacy chat channel remains active during TGUI startup or after
a panel failure, but is not sent a duplicate copy once TGUI is ready.

## Deployment bookkeeping which should not be served

Every publication writes `<prefix>-<namespace>-latest.json` beside the archives:
the manifest of the deployment which produced them, kept for operators and
monitoring. The namespace segment is the same one archive names carry, so
instances sharing one `RSC_PUBLISH_DIR` do not overwrite each other's report.
The build browser inventories below `browser-assets/.manifests/`, immutable
release contracts in `.releases/`, and the small `-active.json` pointer serve
the same bookkeeping and activation purpose. DreamDaemon does not modify them.

A host which deployed before the namespace segment existed still has the old
unnamespaced `<prefix>-latest.json` sitting in `RSC_PUBLISH_DIR`. Nothing writes
to it any more and pruning ignores it, so it stays forever, showing a stale
commit to anyone who reads it. Delete it once by hand.

No client fetches either of them: BYOND downloads the archive and TGUI fetches
individual asset files. They expose the deployed commit, the resource digests
and the full list of published files, which is an inventory of the server worth
nothing to a player and something to somebody probing the host, so the simplest
policy is not to serve them:

```nginx
location ~ ^/byond_rsc/.*-latest\.json$ {
    return 404;
}

location ~ ^/byond_rsc/.*-active\.json$ {
    return 404;
}

location ~ ^/byond_rsc/\.releases/ {
    return 404;
}

location ~ ^/byond_rsc/.*/\.manifests/ {
    return 404;
}
```

Both patterns are anchored to the distribution prefix on purpose: an unanchored
`location ~ -latest\.json$` is a server-wide rule and would blank out unrelated
files on any other site served by the same `server` block. Change `/byond_rsc/`
to match `RSC_PUBLIC_BASE_URL`, exactly as in the CORS location above.

Regex locations win over the prefix locations above, so both rules apply to the
`browser-assets/` location as well. Serving them anyway leaks nothing secret;
this is defence in depth, not a fix for a vulnerability.

## RSC mirrors

Set `RSC_PUBLIC_MIRROR_BASE_URLS` to a semicolon-separated list of HTTP(S) base
URLs when the same immutable archives are available through multiple hosts.
The generated DMB rotates connecting clients across the primary URL and these
mirrors, using the same behavior as `EXTERNAL_RSC_URLS` for unmanaged builds.

PostCompile writes only `RSC_PUBLISH_DIR`; it does not upload to remote mirrors.
Each configured URL must therefore be an alias, shared-storage frontend, or a
mirror synchronized before TGS activates the new DMB. Do not configure a mirror
which can lag behind publication, because clients assigned to it will fall back
to resource delivery through DreamDaemon. When `RSC_VERIFY_PUBLIC_URL=1`,
PostCompile checks the versioned archive and one representative of each enabled
browser/lobby component through every configured URL, and stores the per-address
results in the deployment manifest. With
`RSC_REQUIRE_PUBLIC_VERIFICATION=1`, any failed check (or a missing declared
browser source) aborts before the atomic active pointer is replaced. Leave it at
the default `0` when the public frontend is intentionally unreachable from the
TGS host. The runtime CDN probe also checks every URL in the client rotation.

No production URL needs to be edited on later deployments. The unmanaged config
retains the download-host archive alias as its fallback; managed builds
use names such as `Moon-Blue-<archive-input-sha256>.zip`. Every publication
relinks that unversioned alias (`RSC_LEGACY_ALIAS_NAME`, by default the archive
prefix plus `.zip`) to the archive of the current deployment, so a build without
an embedded deployment URL — an unmanaged server, or a deployment made while
this config was absent — still resolves `EXTERNAL_RSC_URLS`. It is a hard link
where the filesystem supports one, cleanup only owns the versioned names, and a
failure to refresh it is logged without failing the deployment. The relink
happens only after public verification: a release rejected by
`RSC_REQUIRE_PUBLIC_VERIFICATION=1` leaves the previous alias untouched. Because that
name is not content-addressed, it must not be served with an `immutable` cache
policy. That hash covers
resource/build inputs and a stable deployment namespace derived from the
persistent config path, preventing separate TGS instances on one publish
directory from colliding. `RSC_DEPLOYMENT_NAMESPACE` can override the derived
namespace for hosts which need an explicit stable identity. Code-only deployments
whose referenced resource inputs and compiled RSC size are unchanged reuse the
same URL and preserve client caches. Unreferenced media such as TGUI source and
browser bundles does not participate in this fingerprint, and neither does the
deployment tooling: editing a TGS hook or this script decides how an archive is
published, never what DreamMaker embeds, so it must not evict every client's
copy. The BYOND version from `.tgs.yml` does participate, because another
compiler may lay the resource container out differently.

The nginx `immutable` cache policy is appropriate for these names. PostCompile
automatically inventories `.rsc-deploy.json` next to every DMB in the TGS `Game`
directory and protects all referenced archives before pruning. This follows the
TGS deployment lifecycle: directories remain present while a compile job is the
latest or is locked by a running DreamDaemon, and are deleted after the locks
are released. Cleanup keeps two additional unreferenced archives and applies a
24-hour grace period by default. It aborts without deleting anything if a DMB
has no manifest, a manifest cannot be read, or the deployment root is unknown.

Lobby and browser content stores are pruned under the same grace policy.
PostCompile records every lobby file and writes a per-DMB browser asset inventory
below `browser-assets/.manifests/`; files referenced by any deployable DMB
inventory are protected. During rollout, an older DMB without these fields disables the
corresponding cleanup instead of making assumptions. Turning off lobby
publication removes `config/lobby_media.json`, and turning off managed webroot
configuration removes only the managed override block, restoring the
operator-authored `ASSET_*` values left in place.

`RSC_DEPLOYMENT_ROOTS` is inferred from the normal
`Configuration/GameStaticFiles/config` layout. If multiple TGS instances share
one `RSC_PUBLISH_DIR`, configure every absolute `Game` directory as a
semicolon-separated list so an archive used by another instance is protected.
Both `lobby-media/` and `browser-assets/` are served below the already configured
public base URL, so no additional nginx location is needed when the publish
directory is served recursively.
