#!/usr/bin/env bash
# Installs (or updates) a vantaflow macOS app from its latest GitHub release.
#   curl -fsSL https://vantaflow.github.io/install.sh | bash -s <app>
#   curl -fsSL https://vantaflow.github.io/install.sh | bash          # lists the apps
# Downloaded with curl, the app carries no quarantine flag, so Gatekeeper does
# not block it on first launch even though it is not notarized.
#
# Options (environment variables):
#   VF_VERSION=v1.2.3     install that release tag instead of the newest Mac build
#   VF_DEST=/Applications install folder
#   VF_NO_OPEN=1          do not launch the app afterwards
set -euo pipefail

OWNER="vantaflow"
DEST="${VF_DEST:-/Applications}"

# alias|repo|description
APPS="
cleanmac|cleanmac-pro|CleanMac Pro — nettoyeur de disque natif
utv|ultra-tv|Ultra TV — lecteur IPTV
ktv|ktv|KTV — lecteur Xtream Codes
ktv-flutter|ktv-flutter|KTV (Flutter) — lecteur Xtream/IPTV
md-reader|md-reader|MD Reader — éditeur Markdown
lyra|lyra|Lyra — navigateur web
csm|claude-sessions-manager|Claude Sessions — sessions Claude Code
sessions|sessions-manager|Sessions Manager Suite
agy|agy-sessions-manager|AGY Sessions — sessions Antigravity
fsm|free-session-manager|Free Session Manager
"

say()  { printf '\033[1;35m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[1;31mErreur :\033[0m %s\n' "$*" >&2; exit 1; }

list_apps() {
    echo "Usage : curl -fsSL https://vantaflow.github.io/install.sh | bash -s <app>"
    echo
    echo "Apps disponibles :"
    echo "$APPS" | while IFS='|' read -r alias repo desc; do
        [[ -n "$alias" ]] && printf '  %-12s %s\n' "$alias" "$desc"
    done
}

app="${1:-}"
if [[ -z "$app" || "$app" == "-h" || "$app" == "--help" ]]; then list_apps; exit 0; fi

repo=""
while IFS='|' read -r alias r _; do
    if [[ -n "$alias" && ( "$app" == "$alias" || "$app" == "$r" ) ]]; then repo="$r"; fi
done <<< "$APPS"
[[ -n "$repo" ]] || { list_apps >&2; fail "app inconnue : $app"; }

[[ "$(uname -s)" == "Darwin" ]] || fail "ce script installe des apps macOS."
arch="$(uname -m)"   # arm64 | x86_64

# Picks the newest release that has a Mac build for this CPU. JSON is parsed with
# JavaScript for Automation (osascript), which every Mac has — no jq/python needed.
say "Recherche de la dernière version Mac de ${repo}…"
if [[ -n "${VF_VERSION:-}" ]]; then
    api="https://api.github.com/repos/$OWNER/$repo/releases/tags/$VF_VERSION"
else
    api="https://api.github.com/repos/$OWNER/$repo/releases?per_page=40"
fi
tmp="$(mktemp -d)"
mnt=""
cleanup() { [[ -n "$mnt" ]] && hdiutil detach -quiet "$mnt" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

# A token (optional) lifts the 60 requests/hour anonymous API limit.
if [[ -n "${GH_TOKEN:-}" ]]; then
    curl -fsSL -H 'Accept: application/vnd.github+json' -H "Authorization: Bearer $GH_TOKEN" -o "$tmp/releases.json" "$api"
else
    curl -fsSL -H 'Accept: application/vnd.github+json' -o "$tmp/releases.json" "$api"
fi || fail "API GitHub injoignable ($api)."

pick="$(VF_JSON="$tmp/releases.json" VF_ARCH="$arch" osascript -l JavaScript -e '
  const env = $.NSProcessInfo.processInfo.environment;
  const get = k => ObjC.unwrap(env.objectForKey(k));
  let rels = JSON.parse(ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(get("VF_JSON"), $.NSUTF8StringEncoding, null)));
  if (!Array.isArray(rels)) rels = [rels];
  const arm = get("VF_ARCH") === "arm64";
  function score(n) {
    const s = n.toLowerCase();
    if (!/\.(zip|dmg)$/.test(s)) return 0;
    if (/blockmap|\.apk|windows|win-|setup|linux|appimage|\.deb/.test(s)) return 0;
    const mac = /mac|darwin|osx|\.dmg$/.test(s);
    const isArm = /arm64|aarch64/.test(s), isX64 = /x64|x86_64|intel|amd64/.test(s), uni = /universal/.test(s);
    if (!mac && !isArm && !isX64 && !uni) return 0;
    let p = 0;
    if (arm) p = isArm ? 30 : uni ? 20 : isX64 ? 0 : 10;
    else     p = isX64 ? 30 : uni ? 20 : isArm ? 0 : 10;
    if (p === 0) return 0;
    if (mac) p += 5;
    if (s.endsWith(".zip")) p += 1;   // zip: no mount needed
    return p;
  }
  let out = "";
  for (const r of rels) {
    if (r.draft) continue;
    let best = null, bs = 0;
    for (const a of (r.assets || [])) { const sc = score(a.name); if (sc > bs) { bs = sc; best = a; } }
    if (best) { out = r.tag_name + "\t" + best.browser_download_url; break; }
  }
  out;
')"
[[ -n "$pick" ]] || fail "aucun build macOS ($arch) trouvé dans les releases de $repo."
tag="${pick%%$'\t'*}"; url="${pick#*$'\t'}"

say "Téléchargement de ${url##*/} (${tag})…"
curl -fL --progress-bar -o "$tmp/${url##*/}" "$url"

src_dir="$tmp/x"
case "$url" in
    *.zip) ditto -x -k "$tmp/${url##*/}" "$src_dir" ;;
    *.dmg) mnt="$tmp/mnt"; mkdir -p "$mnt"
           hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mnt" "$tmp/${url##*/}"
           src_dir="$mnt" ;;
esac
app_src="$(find "$src_dir" -maxdepth 3 -name '*.app' -type d -prune | head -1)"
[[ -n "$app_src" ]] || fail "aucune app .app dans l'archive."
app_name="${app_src##*/}"

# Quit a running copy so it can be replaced.
bin="$(defaults read "$app_src/Contents/Info" CFBundleExecutable 2>/dev/null || true)"
if [[ -n "$bin" ]] && pgrep -xq "$bin"; then
    say "Fermeture de ${app_name%.app}…"
    osascript -e "quit app \"${app_name%.app}\"" >/dev/null 2>&1 || true
    sleep 2
    pkill -x "$bin" 2>/dev/null || true
fi

as_needed() { if [[ -w "$DEST" ]]; then "$@"; else sudo "$@"; fi; }
mkdir -p "$DEST" 2>/dev/null || sudo mkdir -p "$DEST"
say "Installation de ${app_name} dans ${DEST}…"
as_needed rm -rf "$DEST/$app_name"
as_needed ditto "$app_src" "$DEST/$app_name"
as_needed xattr -dr com.apple.quarantine "$DEST/$app_name" 2>/dev/null || true

version="$(defaults read "$DEST/$app_name/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "$tag")"
say "${app_name%.app} ${version} installé ✓"
if [[ -z "${VF_NO_OPEN:-}" ]]; then open "$DEST/$app_name"; fi
