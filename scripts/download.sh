#!/usr/bin/env bash
# Refresh a dedicated toolchain/model repository to one current snapshot.
# Default is a no-op plan. --apply changes the local tree; --push also
# root-squashes and force-pushes the named branch after explicit confirmation.
#
# Install this file in the asset repository root (for example as download.sh),
# commit it, and run it from that repository. The running tracked script is
# preserved by default; the replacement snapshot is built as one orphan commit
# instead of using an interactive root rebase.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  download.sh --repo PATH --branch BRANCH [--remote NAME] [--apply] [--push]
              [--keep PATH]... [--from-stage DIR]
              [--no-go-tools] [--no-vulndb] [--no-rust] [--no-models]

Environment overrides:
  GOOS=linux GOARCH=amd64
  RUST_HOST=x86_64-unknown-linux-gnu
  RUST_COMPONENTS=rustc,rust-std,cargo,rustfmt,clippy,rust-src,rust-analyzer
  RUST_TARGETS=                      # extra rust-std targets, comma-separated
  GITHUB_TOKEN=                      # optional GitHub API/release authentication

Default is dry-run. --push requires --apply, a clean checkout at the remote tip,
Git LFS, and interactive confirmations. The running script must be a tracked,
unmodified regular file inside --repo; it is copied into the new snapshot and
excluded from tracked-tree deletion. --keep preserves additional tracked files.
--from-stage applies an already prepared stage directory without downloading.
EOF
}

die() { printf 'download: %s\n' "$*" >&2; exit 1; }
sha256_file() { sha256sum -- "$1" | awk '{print $1}'; }

confirm() {
  local expected="$1" answer
  [[ -t 0 ]] || die "confirmation requires an interactive terminal: $expected"
  printf 'Type exactly [%s] to continue: ' "$expected" >&2
  read -r answer
  [[ "$answer" == "$expected" ]] || die "cancelled"
}

safe_rel() {
  local path="$1"
  [[ -n "$path" && "$path" != /* && "$path" != *\\* && "$path" != *'..'* && "$path" != .git/* ]] ||
    die "unsafe relative path: $path"
}

REPO='' REMOTE=origin BRANCH='' APPLY=0 PUSH=0 FROM_STAGE=''
NO_GO_TOOLS=0 NO_VULNDB=0 NO_RUST=0 NO_MODELS=0
declare -a KEEP=()
while (($#)); do
  case "$1" in
    --repo)   (($# >= 2)) || die '--repo needs a path'; REPO="$2"; shift 2 ;;
    --remote) (($# >= 2)) || die '--remote needs a name'; REMOTE="$2"; shift 2 ;;
    --branch) (($# >= 2)) || die '--branch needs a name'; BRANCH="$2"; shift 2 ;;
    --keep)   (($# >= 2)) || die '--keep needs a path'; KEEP+=("$2"); shift 2 ;;
    --from-stage) (($# >= 2)) || die '--from-stage needs a directory'; FROM_STAGE="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --push) PUSH=1; shift ;;
    --no-go-tools) NO_GO_TOOLS=1; shift ;;
    --no-vulndb) NO_VULNDB=1; shift ;;
    --no-rust) NO_RUST=1; shift ;;
    --no-models) NO_MODELS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$REPO" && -n "$BRANCH" ]] || { usage >&2; exit 2; }
(( PUSH == 0 || APPLY == 1 )) || die '--push requires --apply'
REPO="$(cd "$REPO" && pwd -P)" || die "cannot enter repo: $REPO"
TOP="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || die "not a Git repository: $REPO"
[[ "$TOP" == "$REPO" ]] || die '--repo must be the repository root'
[[ "$(basename "$REPO")" != "expert-winner" ]] || die 'refusing to rewrite expert-winner'
git -C "$REPO" check-ref-format "refs/heads/$BRANCH" || die "invalid branch: $BRANCH"

CURRENT_BRANCH="$(git -C "$REPO" branch --show-current)"
[[ "$CURRENT_BRANCH" == "$BRANCH" ]] || die "checkout $BRANCH first (currently $CURRENT_BRANCH)"
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || die 'target worktree is not clean'

REMOTE_URL="$(git -C "$REPO" remote get-url "$REMOTE" 2>/dev/null)" || die "no remote named $REMOTE"
case "${REMOTE_URL,,}" in
  *wshyang/expert-winner*) die 'refusing to operate on the expert-winner remote' ;;
esac

ORIGINAL_HEAD="$(git -C "$REPO" rev-parse HEAD)" || die 'target branch has no commit'
if (( PUSH )); then
  git -C "$REPO" fetch --no-tags "$REMOTE" "refs/heads/$BRANCH"
  REMOTE_BEFORE="$(git -C "$REPO" rev-parse FETCH_HEAD)"
  [[ "$REMOTE_BEFORE" == "$ORIGINAL_HEAD" ]] ||
    die 'local branch is not exactly at the remote tip; refusing force-push'
fi

command -v realpath >/dev/null || die 'missing required tool: realpath'
SELF="$(realpath -- "${BASH_SOURCE[0]}")" || die 'cannot resolve running script'
[[ -f "$SELF" && ! -L "$SELF" ]] || die 'running script must be a regular non-symlink file'
case "$SELF" in
  "$REPO"/*) SELF_REL="${SELF#"$REPO/"}" ;;
  *) die 'run the tracked script from inside the asset repository; refusing to delete a script it cannot preserve' ;;
esac
safe_rel "$SELF_REL"
git -C "$REPO" ls-files --error-unmatch -- "$SELF_REL" >/dev/null 2>&1 ||
  die "commit the running script first: $SELF_REL"
SELF_SHA_BEFORE="$(sha256_file "$SELF")"

declare -A PRESERVE=()
PRESERVE["$SELF_REL"]=1
for path in "${KEEP[@]}"; do
  safe_rel "$path"
  git -C "$REPO" ls-files --error-unmatch -- "$path" >/dev/null 2>&1 ||
    die "--keep path is not tracked: $path"
  [[ -f "$REPO/$path" && ! -L "$REPO/$path" ]] || die "--keep path must be a regular non-symlink file: $path"
  PRESERVE["$path"]=1
done

if [[ -n "$FROM_STAGE" ]]; then
  FROM_STAGE="$(cd "$FROM_STAGE" && pwd -P)" || die "cannot enter stage: $FROM_STAGE"
  [[ -d "$FROM_STAGE" ]] || die "--from-stage is not a directory: $FROM_STAGE"
  [[ ! -e "$FROM_STAGE/.git" ]] || die '--from-stage must not contain .git'
fi

if (( ! APPLY )); then
  printf 'Dry run only.\nRepo: %s\nRemote: %s (%s)\nBranch: %s\nPreserved script: %s\n' \
    "$REPO" "$REMOTE" "$REMOTE_URL" "$BRANCH" "$SELF_REL"
  for path in "${!PRESERVE[@]}"; do
    [[ "$path" == "$SELF_REL" ]] || printf 'Preserved extra: %s\n' "$path"
  done
  if [[ -n "$FROM_STAGE" ]]; then
    printf 'Would apply prepared stage: %s\n' "$FROM_STAGE"
  else
    printf 'Would fetch current stable Go, Go review tools, Go vulnerability DB, Rust components, and sandbox models.\n'
  fi
  if (( PUSH )); then
    printf 'Would replace the tracked tree, create one orphan snapshot commit, then force-push with a lease.\n'
  else
    printf 'Would replace the tracked tree and create one orphan snapshot commit locally; no push.\n'
  fi
  exit 0
fi

for tool in python3 sha256sum git awk find du sort xargs flock; do
  command -v "$tool" >/dev/null || die "missing required tool: $tool"
done
if [[ -z "$FROM_STAGE" ]]; then
  command -v curl >/dev/null || die 'missing required tool: curl'
  command -v tar >/dev/null || die 'missing required tool: tar'
fi
git -C "$REPO" lfs version >/dev/null 2>&1 || die 'Git LFS is required for large archives/weights'
python3 -c 'import sys; sys.version_info >= (3,11) or sys.exit("Python 3.11+ required (tomllib)")'

GOOS="${GOOS:-linux}"
GOARCH="${GOARCH:-amd64}"
RUST_HOST="${RUST_HOST:-x86_64-unknown-linux-gnu}"
RUST_COMPONENTS="${RUST_COMPONENTS:-rustc,rust-std,cargo,rustfmt,clippy,rust-src,rust-analyzer}"
RUST_TARGETS="${RUST_TARGETS:-}"

TMP="$(mktemp -d)"
STAGE="$TMP/tree"
mkdir -p "$STAGE"
BACKUP_REF=''
MUTATED=0

exec 9>"$REPO/.git/download-refresh.lock"
flock -n 9 || die 'another download.sh refresh holds the repository lock'

cleanup() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 && MUTATED == 1 )) && [[ -n "$BACKUP_REF" ]]; then
    git -C "$REPO" reset --hard "$BACKUP_REF" >/dev/null 2>&1 || true
    git -C "$REPO" clean -fd >/dev/null 2>&1 || true
  fi
  rm -rf -- "$TMP"
  exit "$rc"
}
trap cleanup EXIT

GH_CURL=(curl -fsSL --retry 3 --proto '=https' --tlsv1.2 -H 'Accept: application/vnd.github+json')
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  GH_CURL+=(-H "Authorization: Bearer $GITHUB_TOKEN")
fi

GO_VERSION='' GO_FILE='' GO_SHA='' GO_TOOLS_VERSION='' VULNDB_DATE='' VULNDB_SHA=''
RUST_VERSION='' MODEL_REV='' MODEL_LICENSE='' SPACY_URL='' SPACY_TAG='en_core_web_sm-3.8.0'

if [[ -n "$FROM_STAGE" ]]; then
  cp -a -- "$FROM_STAGE/." "$STAGE/"
else
  # Go: select the first stable release with the requested OS/architecture.
  curl -fsSL --retry 3 'https://go.dev/dl/?mode=json&include=all' -o "$TMP/go.json"
  GO_META="$(python3 - "$TMP/go.json" "$GOOS" "$GOARCH" <<'PY_GO_META'
import json, sys
releases = json.load(open(sys.argv[1], encoding='utf-8'))
for release in releases:
    if not release.get('stable'):
        continue
    f = next((x for x in release.get('files', [])
              if x.get('os') == sys.argv[2] and x.get('arch') == sys.argv[3]
              and x.get('kind') == 'archive'), None)
    if f:
        print('\t'.join((release['version'], f['filename'], f['sha256'])))
        break
else:
    raise SystemExit(f'no stable Go archive for {sys.argv[2]}/{sys.argv[3]}')
PY_GO_META
)"
  IFS=$'\t' read -r GO_VERSION GO_FILE GO_SHA <<< "$GO_META"
  [[ "$GO_VERSION" =~ ^go[0-9] && "$GO_FILE" != */* ]] || die 'invalid Go release metadata'
  GO_TMP="$TMP/$GO_FILE"
  curl -fLsS --retry 3 "https://go.dev/dl/$GO_FILE" -o "$GO_TMP"
  [[ "$(sha256_file "$GO_TMP")" == "$GO_SHA" ]] || die 'Go archive SHA-256 mismatch'
  mkdir -p "$STAGE/toolchains/go/$GO_VERSION/$GOOS-$GOARCH"
  cp -- "$GO_TMP" "$STAGE/toolchains/go/$GO_VERSION/$GOOS-$GOARCH/$GO_FILE"

  # Extract the verified Go toolchain so review tools are built with the same Go.
  GO_ROOT="$TMP/goroot"
  mkdir -p "$GO_ROOT"
  case "$GO_FILE" in
    *.tar.gz) tar -xzf "$GO_TMP" -C "$GO_ROOT" --strip-components=1 ;;
    *.zip)
      python3 - "$GO_TMP" "$GO_ROOT" <<'PY_GO_ZIP'
import sys, zipfile
from pathlib import Path
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in z.namelist():
        p = Path(name)
        if p.is_absolute() or '..' in p.parts:
            raise SystemExit(f'unsafe Go zip member: {name}')
    z.extractall(sys.argv[2])
root = Path(sys.argv[2])
if (root / 'go').is_dir():
    for child in (root / 'go').iterdir():
        child.rename(root / child.name)
    (root / 'go').rmdir()
PY_GO_ZIP
      ;;
    *) die "unsupported Go archive format: $GO_FILE" ;;
  esac
  GO_CMD="$GO_ROOT/bin/go"
  [[ -x "$GO_CMD" ]] || die 'extracted Go toolchain has no bin/go'
  "$GO_CMD" version

  if (( ! NO_GO_TOOLS )); then
    GO_TOOLS_DIR="$STAGE/toolchains/go-tools/$GO_VERSION/$GOOS-$GOARCH"
    mkdir -p "$GO_TOOLS_DIR/bin"
    export GOROOT="$GO_ROOT"
    export GOPATH="$TMP/gopath" GOMODCACHE="$TMP/gomodcache" GOCACHE="$TMP/gocache"
    export GOBIN="$GO_TOOLS_DIR/bin" GOTOOLCHAIN=local GOFLAGS=-trimpath CGO_ENABLED=0
    : > "$GO_TOOLS_DIR/TOOLS.tsv"
    printf 'name\tmodule\tversion\tbinary_sha256\n' >> "$GO_TOOLS_DIR/TOOLS.tsv"

    install_go_tool() {
      local name="$1" module="$2" query="${3:-latest}" version binary
      version="$("$GO_CMD" list -m -json "$module@$query" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Version"])')"
      [[ -n "$version" ]] || die "could not resolve $module"
      "$GO_CMD" install "$module@$version"
      binary="$GOBIN/$name"
      [[ -x "$binary" ]] || die "go install did not produce $name"
      "$GO_CMD" version -m "$binary" > "$GO_TOOLS_DIR/$name.buildinfo.txt"
      printf '%s\t%s\t%s\t%s\n' "$name" "$module" "$version" "$(sha256_file "$binary")" >> "$GO_TOOLS_DIR/TOOLS.tsv"
    }

    install_go_tool staticcheck honnef.co/go/tools/cmd/staticcheck
    install_go_tool govulncheck golang.org/x/vuln/cmd/govulncheck
    install_go_tool goimports golang.org/x/tools/cmd/goimports
    install_go_tool gopls golang.org/x/tools/gopls

    # golangci-lint recommends official binaries over go install.
    "${GH_CURL[@]}" 'https://api.github.com/repos/golangci/golangci-lint/releases/latest' -o "$TMP/golangci-release.json"
    GCL_META="$(python3 - "$TMP/golangci-release.json" "$GOOS" "$GOARCH" <<'PY_GCL'
import json, sys
release = json.load(open(sys.argv[1], encoding='utf-8'))
tag = release.get('tag_name', '')
if not tag:
    raise SystemExit('golangci-lint release has no tag')
version = tag.removeprefix('v')
suffix = f'-{sys.argv[2]}-{sys.argv[3]}'
asset = next((a for a in release.get('assets', [])
              if a.get('name', '').startswith(f'golangci-lint-{version}{suffix}')
              and a.get('name', '').endswith(('.tar.gz', '.zip'))), None)
checksums = next((a for a in release.get('assets', []) if a.get('name', '') == f'golangci-lint-{version}-checksums.txt'), None)
if not asset or not checksums:
    raise SystemExit(f'golangci-lint release asset/checksums missing for {sys.argv[2]}/{sys.argv[3]}')
print('\t'.join((version, asset['name'], asset['browser_download_url'], checksums['browser_download_url'])))
PY_GCL
)"
    IFS=$'\t' read -r GCL_VERSION GCL_FILE GCL_URL GCL_SUMS_URL <<< "$GCL_META"
    curl -fLsS --retry 3 "$GCL_URL" -o "$TMP/$GCL_FILE"
    curl -fLsS --retry 3 "$GCL_SUMS_URL" -o "$TMP/golangci-checksums.txt"
    GCL_SHA="$(awk -v f="$GCL_FILE" '$2 == f || $2 == "*" f {print $1; exit}' "$TMP/golangci-checksums.txt")"
    [[ -n "$GCL_SHA" && "$(sha256_file "$TMP/$GCL_FILE")" == "$GCL_SHA" ]] ||
      die 'golangci-lint SHA-256 mismatch'
    mkdir -p "$TMP/golangci"
    case "$GCL_FILE" in
      *.tar.gz) tar -xzf "$TMP/$GCL_FILE" -C "$TMP/golangci" --strip-components=1 ;;
      *.zip)
        python3 - "$TMP/$GCL_FILE" "$TMP/golangci" <<'PY_GCL_ZIP'
import sys, zipfile
from pathlib import Path
with zipfile.ZipFile(sys.argv[1]) as z:
    for name in z.namelist():
        p = Path(name)
        if p.is_absolute() or '..' in p.parts:
            raise SystemExit(f'unsafe golangci-lint zip member: {name}')
    z.extractall(sys.argv[2])
root = Path(sys.argv[2])
dirs = [p for p in root.iterdir() if p.is_dir()]
if len(dirs) == 1:
    for child in dirs[0].iterdir():
        child.rename(root / child.name)
    dirs[0].rmdir()
PY_GCL_ZIP
        ;;
    esac
    cp -- "$TMP/golangci/golangci-lint" "$GO_TOOLS_DIR/bin/golangci-lint"
    chmod +x "$GO_TOOLS_DIR/bin/golangci-lint"
    printf '%s\t%s\t%s\t%s\n' 'golangci-lint' 'github.com/golangci/golangci-lint' "v$GCL_VERSION" "$(sha256_file "$GO_TOOLS_DIR/bin/golangci-lint")" >> "$GO_TOOLS_DIR/TOOLS.tsv"
    GO_TOOLS_VERSION="$GCL_VERSION"
    # Keep review-tool binaries as ordinary Git blobs so a plain GitHub clone can
    # fetch them without LFS media access. GitHub rejects files over 100 MiB.
    if find "$GO_TOOLS_DIR/bin" -type f -size +95M -print -quit | grep -q .; then
      die 'a Go review-tool binary exceeds 95 MiB; mirror it separately or adjust storage policy'
    fi

    if (( ! NO_VULNDB )); then
      curl -fLsS --retry 3 'https://vuln.go.dev/vulndb.zip' -o "$TMP/vulndb.zip"
      VULNDB_SHA="$(sha256_file "$TMP/vulndb.zip")"
      VULNDB_DATE="$(python3 - "$TMP/vulndb.zip" "$TMP/vulndb" <<'PY_VULNDB'
import json, sys, zipfile
from pathlib import Path
archive, out = Path(sys.argv[1]), Path(sys.argv[2])
out.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(archive) as z:
    for info in z.infolist():
        p = Path(info.filename)
        if p.is_absolute() or '..' in p.parts:
            raise SystemExit(f'unsafe vulndb member: {info.filename}')
    z.extractall(out)
root = out
if not (root / 'index/db.json').is_file():
    candidates = [p for p in out.iterdir() if p.is_dir() and (p / 'index/db.json').is_file()]
    if len(candidates) != 1:
        raise SystemExit('vulndb.zip has no unique index/db.json')
    root = candidates[0]
db = json.loads((root / 'index/db.json').read_text(encoding='utf-8'))
modules = json.loads((root / 'index/modules.json').read_text(encoding='utf-8'))
if not modules:
    raise SystemExit('vulndb index/modules.json is empty')
modified = str(db.get('modified', ''))
date = modified.split('T', 1)[0] if modified else 'snapshot'
print(date)
print(root, file=sys.stderr)
PY_VULNDB
)"
      # The Python helper prints the extracted root on stderr; recover it deterministically.
      VULNDB_ROOT="$TMP/vulndb"
      if [[ ! -f "$VULNDB_ROOT/index/db.json" ]]; then
        VULNDB_ROOT="$(find "$TMP/vulndb" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
      fi
      [[ -f "$VULNDB_ROOT/index/db.json" && -f "$VULNDB_ROOT/index/modules.json" ]] ||
        die 'extracted Go vulnerability database is incomplete'
      mkdir -p "$STAGE/toolchains/go-vulndb/$VULNDB_DATE"
      cp -a -- "$VULNDB_ROOT/." "$STAGE/toolchains/go-vulndb/$VULNDB_DATE/"
    fi
  fi

  if (( ! NO_RUST )); then
    # Rust: use the stable-channel manifest's published URLs and SHA-256s.
    curl -fsSL --retry 3 'https://static.rust-lang.org/dist/channel-rust-stable.toml' \
      -o "$TMP/rust-channel.toml"
    python3 - "$TMP/rust-channel.toml" "$RUST_HOST" "$RUST_COMPONENTS" "$RUST_TARGETS" > "$TMP/rust.tsv" <<'PY_RUST'
import sys, tomllib
manifest = tomllib.load(open(sys.argv[1], 'rb'))
host = sys.argv[2]
requested = [x.strip() for x in sys.argv[3].split(',') if x.strip()]
extra_targets = [x.strip() for x in sys.argv[4].split(',') if x.strip()]
required_core = {'rustc', 'rust-std', 'cargo'}
components = list(dict.fromkeys(requested + sorted(required_core)))
version = manifest['pkg']['rustc']['version'].split()[0]
print(f'VERSION\t{version}')
aliases = {
    'rustfmt': ('rustfmt', 'rustfmt-preview'),
    'clippy': ('clippy', 'clippy-preview'),
    'rust-analyzer': ('rust-analyzer', 'rust-analyzer-preview'),
    'llvm-tools': ('llvm-tools', 'llvm-tools-preview'),
    'miri': ('miri', 'miri-preview'),
}
def entry_for(component, target):
    pkg = manifest.get('pkg', {})
    for name in aliases.get(component, (component,)):
        entry = pkg.get(name, {}).get('target', {}).get(target)
        if entry:
            return name, entry
    return None, None
jobs = [(component, '*' if component == 'rust-src' else host) for component in components]
jobs += [('rust-std', target) for target in extra_targets if target != host]
seen = set()
for component, target in jobs:
    key = (component, target)
    if key in seen:
        continue
    seen.add(key)
    package, entry = entry_for(component, target)
    if not entry or not entry.get('available', False):
        raise SystemExit(f'{component} unavailable for {target}')
    url, digest = entry.get('xz_url'), entry.get('xz_hash')
    if not url or not digest:
        raise SystemExit(f'{component} has no xz URL/SHA-256 in channel manifest')
    print('\t'.join((component, package, target, url.rsplit('/', 1)[-1], url, digest.lower())))
PY_RUST
    RUST_VERSION="$(awk -F '\t' '$1 == "VERSION" {print $2}' "$TMP/rust.tsv")"
    [[ -n "$RUST_VERSION" ]] || die 'could not determine stable Rust version'
    RUST_DIR="$STAGE/toolchains/rust/$RUST_VERSION/$RUST_HOST"
    mkdir -p "$RUST_DIR"
    cp -- "$TMP/rust-channel.toml" "$RUST_DIR/channel-rust-stable.toml"
    grep -v '^VERSION' "$TMP/rust.tsv" > "$RUST_DIR/components.tsv"
    while IFS=$'\t' read -r component package target filename url expected; do
      [[ -n "${component:-}" ]] || continue
      printf 'Rust component: %s (%s, %s)\n' "$component" "$package" "$target" >&2
      curl -fLsS --retry 3 "$url" -o "$TMP/$filename"
      [[ "$(sha256_file "$TMP/$filename")" == "$expected" ]] ||
        die "Rust $component ($target) SHA-256 mismatch"
      cp -- "$TMP/$filename" "$RUST_DIR/$filename"
    done < "$RUST_DIR/components.tsv"
  fi

  if (( ! NO_MODELS )); then
    # f-coref is the discussed sandbox-sized coref checkpoint.
    MODEL_ID='biu-nlp/f-coref'
    curl -fsSL --retry 3 "https://huggingface.co/api/models/$MODEL_ID?blobs=true" \
      -o "$TMP/f-coref-info.json"
    MODEL_META="$(python3 - "$TMP/f-coref-info.json" "$TMP/f-coref-files.tsv" <<'PY_MODEL'
import json, sys
info = json.load(open(sys.argv[1], encoding='utf-8'))
license_id = (info.get('cardData') or {}).get('license', '').lower()
if license_id != 'mit':
    raise SystemExit(f'expected MIT license for {info.get("id")}, got {license_id or "unknown"}')
revision = info.get('sha')
if not revision:
    raise SystemExit('Hugging Face API did not return a pinned model revision')
siblings = {x['rfilename']: x for x in info.get('siblings', [])}
required = ['config.json', 'pytorch_model.bin', 'tokenizer_config.json',
            'vocab.json', 'merges.txt', 'special_tokens_map.json', 'tokenizer.json']
optional = ['README.md']
with open(sys.argv[2], 'w', encoding='utf-8') as out:
    for name in required + optional:
        if name not in siblings:
            if name in required:
                raise SystemExit(f'required model file missing: {name}')
            continue
        lfs = siblings[name].get('lfs') or {}
        digest = lfs.get('sha256') or lfs.get('oid') or '-'
        if digest.startswith('sha256:'):
            digest = digest.split(':', 1)[1]
        if name == 'pytorch_model.bin' and digest == '-':
            raise SystemExit('pytorch_model.bin has no published LFS SHA-256')
        out.write(f'{name}\t{digest.lower()}\n')
print(f'{revision}\t{license_id}')
PY_MODEL
)"
    IFS=$'\t' read -r MODEL_REV MODEL_LICENSE <<< "$MODEL_META"
    MODEL_DIR="$STAGE/models/f-coref/$MODEL_REV"
    mkdir -p "$MODEL_DIR"
    while IFS=$'\t' read -r filename expected; do
      curl -fLsS --retry 3 \
        "https://huggingface.co/$MODEL_ID/resolve/$MODEL_REV/$filename?download=true" \
        -o "$MODEL_DIR/$filename"
      if [[ "$expected" != '-' ]]; then
        [[ "$(sha256_file "$MODEL_DIR/$filename")" == "$expected" ]] ||
          die "f-coref $filename SHA-256 mismatch"
      fi
    done < "$TMP/f-coref-files.tsv"

    # This local config setting is required by the pinned fastcoref runtime.
    python3 - "$MODEL_DIR/config.json" <<'PY_CONFIG'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
config = json.loads(path.read_text(encoding='utf-8'))
config['_attn_implementation'] = 'eager'
path.write_text(json.dumps(config, indent=2) + '\n', encoding='utf-8')
PY_CONFIG

    # Small optional tokenizer model; the pre-tokenized f-coref path does not need it.
    "${GH_CURL[@]}" "https://api.github.com/repos/explosion/spacy-models/releases/tags/$SPACY_TAG" \
      -o "$TMP/spacy-release.json"
    SPACY_META="$(python3 - "$TMP/spacy-release.json" <<'PY_SPACY'
import json, sys
release = json.load(open(sys.argv[1], encoding='utf-8'))
name = 'en_core_web_sm-3.8.0-py3-none-any.whl'
asset = next((x for x in release.get('assets', []) if x.get('name') == name), None)
if not asset:
    raise SystemExit(f'wheel missing from GitHub release: {name}')
digest = asset.get('digest') or ''
if digest.startswith('sha256:'):
    digest = digest.split(':', 1)[1]
print(asset['browser_download_url'] + '\t' + digest.lower())
PY_SPACY
)"
    IFS=$'\t' read -r SPACY_URL SPACY_SHA <<< "$SPACY_META"
    SPACY_WHEEL='en_core_web_sm-3.8.0-py3-none-any.whl'
    mkdir -p "$STAGE/models/spacy"
    curl -fLsS --retry 3 "$SPACY_URL" -o "$STAGE/models/spacy/$SPACY_WHEEL"
    if [[ -n "$SPACY_SHA" ]]; then
      [[ "$(sha256_file "$STAGE/models/spacy/$SPACY_WHEEL")" == "$SPACY_SHA" ]] ||
        die 'spaCy model wheel SHA-256 mismatch'
    fi
  fi

  cat > "$STAGE/README.md" <<EOF
# Current toolchains and sandbox-sized models

Generated from official release metadata. See SOURCES.md, INSTALL.md, and SHA256SUMS.

- Go: ${GO_VERSION:-not included} for $GOOS/$GOARCH
- Go review tools: staticcheck, govulncheck, goimports, gopls, golangci-lint${GO_TOOLS_VERSION:+ ($GO_TOOLS_VERSION)} (ordinary Git blobs, no LFS)
- Go vulnerability DB: ${VULNDB_DATE:-not included} (offline file:// source)
- Rust: ${RUST_VERSION:-not included} for $RUST_HOST; components: $RUST_COMPONENTS${RUST_TARGETS:+; extra targets: $RUST_TARGETS}
- Coreference: ${MODEL_REV:+biu-nlp/f-coref at revision $MODEL_REV (license: $MODEL_LICENSE)}${MODEL_REV:-not included}
- Optional tokenizer package: spaCy en_core_web_sm 3.8.0${MODEL_REV:-}${MODEL_REV:+ (included)}

The f-coref config sets _attn_implementation=eager for transformers==4.44.2.
The spaCy package is optional; the current pre-tokenized f-coref path does not need it.
The refresh script preserves itself: $SELF_REL.
EOF

  cat > "$STAGE/SOURCES.md" <<EOF
Go: ${GO_VERSION:-not included} ($GO_FILE), https://go.dev/dl/$GO_FILE, SHA-256 ${GO_SHA:-not included}
Go tools: $STAGE/toolchains/go-tools/$GO_VERSION/$GOOS-$GOARCH/TOOLS.tsv when included; golangci-lint official release binary, other tools built with the staged Go using go install and checksumDB verification.
Go vulnerability DB: https://vuln.go.dev/vulndb.zip, SHA-256 ${VULNDB_SHA:-not included}, extracted snapshot ${VULNDB_DATE:-not included}
Rust: ${RUST_VERSION:-not included} ($RUST_HOST), https://static.rust-lang.org/dist/channel-rust-stable.toml; component URLs/hashes are in components.tsv.
Coref: ${MODEL_REV:+biu-nlp/f-coref revision $MODEL_REV, MIT, https://huggingface.co/biu-nlp/f-coref}${MODEL_REV:-not included}
spaCy: $SPACY_TAG, ${SPACY_URL:-not included}
EOF

  cat > "$STAGE/INSTALL.md" <<EOF
# Offline restoration notes

Verify SHA256SUMS after Git LFS pull:

    sha256sum -c SHA256SUMS

Go toolchain: extract the staged Go archive into a clean prefix. Do not extract over an existing Go tree.

Go review tools: add the staged toolchains/go-tools/.../bin directory to PATH.
For offline govulncheck, use the extracted database:

    govulncheck -db file://\$PWD/toolchains/go-vulndb/${VULNDB_DATE:-SNAPSHOT} ./...

The vulnerability database is a snapshot; refresh it before treating a clean scan as current.
Go race detection still requires a supported platform, cgo, and a host C compiler; this script does not vendor GCC/Clang.

Rust components: extract each staged .tar.xz and run its install.sh into one prefix, for example:

    mkdir -p "\$RUST_PREFIX"
    for archive in toolchains/rust/$RUST_VERSION/$RUST_HOST/*.tar.xz; do
      d="\$(mktemp -d)"
      tar -xJf "\$archive" -C "\$d" --strip-components=1
      (cd "\$d" && ./install.sh --prefix="\$RUST_PREFIX" --disable-ldconfig)
      rm -rf "\$d"
    done

rust-src uses target '*' in the Rust manifest. rustfmt/clippy/rust-analyzer/llvm-tools may appear as *-preview package names; components.tsv records the resolved package.
miri is normally a nightly component and is not included in the stable default.
EOF
fi

# Preserve the running script and any explicitly kept tracked files in the new tree.
for path in "${!PRESERVE[@]}"; do
  mkdir -p "$STAGE/$(dirname -- "$path")"
  cp -p -- "$REPO/$path" "$STAGE/$path"
done
[[ "$(sha256_file "$STAGE/$SELF_REL")" == "$SELF_SHA_BEFORE" ]] ||
  die 'staged script does not match the running script'

if [[ ! -f "$STAGE/README.md" ]]; then
  printf '# Prepared asset stage\n\nApplied from %s.\n' "$FROM_STAGE" > "$STAGE/README.md"
fi
if [[ ! -f "$STAGE/SOURCES.md" ]]; then
  printf 'Prepared stage source: %s\n' "$FROM_STAGE" > "$STAGE/SOURCES.md"
fi

(
  cd "$STAGE"
  find . -type f ! -name SHA256SUMS -print0 | LC_ALL=C sort -z | xargs -0 sha256sum
) > "$STAGE/SHA256SUMS"
printf 'Staged tree size: '
du -sh "$STAGE" | awk '{print $1}'

confirm 'REPLACE TRACKED TREE'
BACKUP_REF="refs/heads/backup/assets-before-$(date -u +%Y%m%dT%H%M%SZ)-$$"
git -C "$REPO" update-ref "$BACKUP_REF" "$ORIGINAL_HEAD"
MUTATED=1

# The clean-worktree check above ensures no user changes are removed here.
# Preserved paths are skipped so the executing script is never unlinked.
while IFS= read -r -d '' path; do
  [[ -z "${PRESERVE[$path]+x}" ]] || continue
  rm -f -- "$REPO/$path"
done < <(git -C "$REPO" ls-files -z)

git -C "$REPO" lfs track \
  'toolchains/**/*.tar.gz' 'toolchains/**/*.tar.xz' 'toolchains/**/*.zip' \
  'models/**/*.bin' 'models/**/*.safetensors' 'models/**/*.whl'
cp -a -- "$STAGE/." "$REPO/"
# Regenerate after .gitattributes is written so the final tree is fully covered.
(
  cd "$REPO"
  find . -mindepth 1 -path './.git' -prune -o -type f ! -name SHA256SUMS -print0 |
    LC_ALL=C sort -z | xargs -0 sha256sum
) > "$REPO/SHA256SUMS"
[[ "$(sha256_file "$SELF")" == "$SELF_SHA_BEFORE" ]] || die 'running script changed during replacement'

# Build one orphan snapshot commit through a temporary index. This avoids an
# interactive root rebase and cannot accidentally retain old asset history.
export GIT_INDEX_FILE="$TMP/index"
git -C "$REPO" read-tree --empty
git -C "$REPO" add -A -- .
TREE_BEFORE="$(git -C "$REPO" write-tree)"
unset GIT_INDEX_FILE
NEW_COMMIT="$(git -C "$REPO" commit-tree "$TREE_BEFORE" -m 'Latest toolchains and sandbox models')"
git -C "$REPO" reset --hard "$NEW_COMMIT"

[[ "$(git -C "$REPO" rev-list --count HEAD)" == 1 ]] ||
  die 'snapshot did not produce exactly one commit'
[[ "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" == "$TREE_BEFORE" ]] ||
  die 'tree changed during snapshot creation'
[[ -z "$(git -C "$REPO" status --porcelain)" ]] ||
  die 'worktree is not clean after snapshot'
git -C "$REPO" ls-files --error-unmatch -- "$SELF_REL" >/dev/null 2>&1 ||
  die 'preserved script is missing from the snapshot'
[[ "$(sha256_file "$SELF")" == "$SELF_SHA_BEFORE" ]] ||
  die 'preserved script hash changed'

if (( PUSH )); then
  printf 'Target: %s %s (remote tip %s)\n' "$REMOTE_URL" "$BRANCH" "$REMOTE_BEFORE"
  confirm "PUSH $REMOTE/$BRANCH"
  git -C "$REPO" lfs push "$REMOTE" "$BRANCH"
  git -C "$REPO" push \
    "--force-with-lease=refs/heads/$BRANCH:$REMOTE_BEFORE" \
    "$REMOTE" "HEAD:refs/heads/$BRANCH"
fi

printf 'Done: %s has one commit on %s. Local recovery ref: %s\n' \
  "$REPO" "$BRANCH" "$BACKUP_REF"
