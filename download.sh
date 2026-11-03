#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 OWNER/ARTIFACT-REPO [RELEASE-TAG]" >&2
  exit 2
fi

REPO="$1"
TAG="${2:-toolchains-$(date -u +%Y%m%d)}"
OUT="${OUT_DIR:-$HOME/arena-toolchains-linux-amd64}"
RUST_TARGET="x86_64-unknown-linux-gnu"

for cmd in curl tar python3 gh; do
  command -v "$cmd" >/dev/null || {
    echo "Required command not found: $cmd" >&2
    exit 1
  }
done
python3 -c 'import tomllib' 2>/dev/null || {
  echo "Python 3.11+ is required (for tomllib)." >&2
  exit 1
}
gh auth status >/dev/null

mkdir -p "$OUT/go" "$OUT/rust-components"

verify_sha256() {
  python3 - "$1" "$2" <<'PY'
import hashlib, sys
path, expected = sys.argv[1], sys.argv[2].lower()
h = hashlib.sha256()
with open(path, "rb") as f:
    for block in iter(lambda: f.read(1024 * 1024), b""):
        h.update(block)
actual = h.hexdigest()
if actual != expected:
    raise SystemExit(f"SHA-256 mismatch for {path}: {actual}")
print(f"SHA-256 OK: {path}")
PY
}

download_verified() {
  local url="$1" dest="$2" expected="$3"

  if [[ -f "$dest" ]]; then
    if verify_sha256 "$dest" "$expected" >/dev/null 2>&1; then
      echo "Reusing verified file: $dest"
      return
    fi
    rm -f "$dest"
  fi

  curl --retry 3 -fL "$url" -o "$dest"
  verify_sha256 "$dest" "$expected"
}

# Go: latest stable Linux amd64 archive.
curl --retry 3 -fsSL 'https://go.dev/dl/?mode=json' -o "$OUT/go/releases.json"
read -r GO_VERSION GO_FILE GO_SHA < <(
  python3 - "$OUT/go/releases.json" <<'PY'
import json, sys
releases = json.load(open(sys.argv[1], encoding="utf-8"))
release = next(r for r in releases if r.get("stable") is True)
asset = next(
    f for f in release["files"]
    if f.get("os") == "linux"
    and f.get("arch") == "amd64"
    and f["filename"].endswith(".linux-amd64.tar.gz")
)
print(release["version"], asset["filename"], asset["sha256"])
PY
)
GO_ARCHIVE="$OUT/go/$GO_FILE"
download_verified "https://go.dev/dl/$GO_FILE" "$GO_ARCHIVE" "$GO_SHA"

# Rust: required compiler, standard library and Cargo; formatting/lint tools
# are included when the current stable manifest offers them.
RUST_DIR="$OUT/rust-components"
RUST_MANIFEST="$RUST_DIR/channel-rust-stable.toml"
RUST_COMPONENTS="$RUST_DIR/components.tsv"

curl --retry 3 -fsSL \
  'https://static.rust-lang.org/dist/channel-rust-stable.toml' \
  -o "$RUST_MANIFEST"

python3 - "$RUST_MANIFEST" "$RUST_COMPONENTS" "$RUST_TARGET" <<'PY'
import sys, tomllib
manifest_path, output_path, target = sys.argv[1:]
packages = tomllib.load(open(manifest_path, "rb")).get("pkg", {})

specs = (
    ("rustc", ("rustc",), True),
    ("rust-std", ("rust-std",), True),
    ("cargo", ("cargo",), True),
    ("rustfmt", ("rustfmt", "rustfmt-preview"), False),
    ("clippy", ("clippy", "clippy-preview"), False),
)

with open(output_path, "w", encoding="utf-8") as out:
    for label, candidates, required in specs:
        package_name = next((name for name in candidates if name in packages), None)
        if package_name is None:
            if required:
                raise SystemExit(f"Required Rust package is missing: {label}")
            print(f"NOTE: optional Rust component {label} not in stable manifest; skipping",
                  file=sys.stderr)
            continue

        info = packages[package_name].get("target", {}).get(target)
        if not info or not info.get("available"):
            if required:
                raise SystemExit(f"Required Rust component {label} unavailable for {target}")
            print(f"NOTE: optional Rust component {label} unavailable for {target}; skipping",
                  file=sys.stderr)
            continue

        if info.get("xz_url") and info.get("xz_hash"):
            url, sha = info["xz_url"], info["xz_hash"]
        else:
            url, sha = info.get("url"), info.get("hash")

        if not url or not sha:
            if required:
                raise SystemExit(f"Missing download/checksum metadata for {label}")
            print(f"NOTE: optional Rust component {label} has no download metadata; skipping",
                  file=sys.stderr)
            continue

        filename = url.rsplit("/", 1)[-1]
        print(label, url, sha, filename, sep="\t", file=out)
PY

: > "$RUST_DIR/SHA256SUMS"
RUST_FILES=()
while IFS=$'\t' read -r component url sha filename; do
  [[ -n "$filename" ]] || continue
  download_verified "$url" "$RUST_DIR/$filename" "$sha"
  printf '%s  %s\n' "$sha" "$filename" >> "$RUST_DIR/SHA256SUMS"
  RUST_FILES+=("$filename")
done < "$RUST_COMPONENTS"

RUSTC_FILE="$(awk -F '\t' '$1 == "rustc" { print $4 }' "$RUST_COMPONENTS")"
RUST_VERSION="${RUSTC_FILE#rustc-}"
RUST_VERSION="${RUST_VERSION%%-*}"
RUST_BUNDLE="$OUT/rust-toolchain-${RUST_VERSION}-${RUST_TARGET}.tar.gz"

tar -C "$RUST_DIR" -czf "$RUST_BUNDLE" \
  components.tsv SHA256SUMS channel-rust-stable.toml "${RUST_FILES[@]}"

# Create the release if absent; otherwise replace assets with matching names.
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$GO_ARCHIVE" "$RUST_BUNDLE" \
    --repo "$REPO" --clobber
else
  gh release create "$TAG" "$GO_ARCHIVE" "$RUST_BUNDLE" \
    --repo "$REPO" \
    --title "Linux amd64 Go and Rust toolchains" \
    --notes "Official toolchain archives; component checksums verified before upload."
fi

echo
echo "Uploaded to $REPO, release $TAG"
echo "Go:   $GO_ARCHIVE ($GO_VERSION)"
echo "Rust: $RUST_BUNDLE ($RUST_VERSION)"
