#!/usr/bin/env bash
#
# Asserts the built image contains a working toolchain. A RUN layer can exit 0
# with a step having failed, so a green build is not evidence of one.
#
#   make check          # lint, build and run this against the result
#   bash smoke-test.sh  # from inside a running container
set -uo pipefail

fail=0
pass=0

# First line carrying a dotted version: some tools put a banner on line 1 and
# the version on line 2 (llvm-*, shellcheck). Falls back to line 1 for tools
# with no version at all, such as GNU time, which reports UNKNOWN.
version_line() {
  { grep -m1 '[0-9][0-9]*\.[0-9]' <<<"$1" || head -n1 <<<"$1"; } | sed 's/^[[:space:]]*//'
}

# Two tiers: `require` must run clean; `present` need only be on PATH, for tools
# whose --version support is unreliable enough that a false failure is the worse
# outcome.
require() {
  local label=$1
  shift
  local out status
  out=$("$@" 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    printf '  ok    %-22s %s\n' "$label" "$(version_line "$out")"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-22s exit %d: %s\n' "$label" "$status" "$(version_line "$out")"
    fail=$((fail + 1))
  fi
}

present() {
  local label=$1 bin=$2
  shift 2
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf '  FAIL  %-22s not on PATH\n' "$label"
    fail=$((fail + 1))
    return
  fi
  local out
  if out=$("$@" 2>&1); then
    printf '  ok    %-22s %s\n' "$label" "$(version_line "$out")"
  else
    printf '  ok    %-22s (present; no usable --version)\n' "$label"
  fi
  pass=$((pass + 1))
}

# Fall back to discovery so the script still works run by hand, without `make`.
if [ -z "${RUST_FMT_TOOLCHAIN:-}" ]; then
  RUST_FMT_TOOLCHAIN=$(rustup toolchain list 2>/dev/null | awk '/^nightly/ {print $1; exit}')
fi

echo "== rust toolchain =="
require "rustc"         rustc --version
require "cargo"         cargo --version
require "clippy"        cargo clippy --version
require "rustfmt"       cargo "+${RUST_FMT_TOOLCHAIN:-nightly}" fmt --version
require "rust-analyzer" rust-analyzer --version
# llvm-tools exists to provide these, so check the binaries rather than the
# component name: `rustup component list` appends the target triple, and the
# component has been spelled both llvm-tools and llvm-tools-preview.
llvm_bin="$(rustc --print target-libdir 2>/dev/null)/../bin"
require "llvm-profdata" "$llvm_bin/llvm-profdata" --version
require "llvm-cov"      "$llvm_bin/llvm-cov" --version
# Optional: an image built with an empty MIRI_TOOLCHAIN has none.
if [ -n "${MIRI_TOOLCHAIN:-}" ]; then
  require "miri"        cargo "+$MIRI_TOOLCHAIN" miri --version
fi

echo
echo "== cargo tooling =="
require "cargo-nextest"    cargo nextest --version
require "cargo-deny"       cargo deny --version
present "cargo-bloat"      cargo-bloat      cargo bloat --version
present "cargo-llvm-lines" cargo-llvm-lines cargo llvm-lines --version
present "cargo-machete"    cargo-machete    cargo machete --version
present "rustfilt"         rustfilt         rustfilt --version

echo
echo "== other tooling =="
require "claude"    claude --version
require "node"      node --version
require "dprint"    dprint --version
require "yq"        yq --version
present "npm"       npm       npm --version
present "git"       git       git --version
present "shellcheck" shellcheck shellcheck --version
present "yamllint"  yamllint  yamllint --version
present "bc"        bc        bc --version
present "gnu-time"  time      /usr/bin/time --version

echo
echo "== build cache layout =="
if [ -n "${CARGO_TARGET_BASE:-}" ]; then
  printf '  ok    %-22s %s\n' "CARGO_TARGET_BASE" "$CARGO_TARGET_BASE"
  pass=$((pass + 1))
else
  printf '  FAIL  %-22s unset\n' "CARGO_TARGET_BASE"
  fail=$((fail + 1))
fi
for dir in "${CARGO_TARGET_BASE:-/nonexistent}" "$HOME/.cargo/registry" "$HOME/.cargo/git"; do
  if [ -w "$dir" ]; then
    printf '  ok    %-22s writable by %s\n' "$(basename "$dir")" "$(id -un)"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-22s not writable by %s (%s)\n' "$(basename "$dir")" "$(id -un)" "$dir"
    fail=$((fail + 1))
  fi
done

# COPY without --chown creates files, and any missing parents, as root, leaving
# the user unable to write there. -xdev stays out of bind mounts, whose owners
# are the host's business.
foreign=$(find "$HOME" -xdev ! -user "$(id -un)" 2>/dev/null | head -n 5 | paste -sd ' ')
if [ -z "$foreign" ]; then
  printf '  ok    %-22s all owned by %s\n' "$HOME" "$(id -un)"
  pass=$((pass + 1))
else
  printf '  FAIL  %-22s not owned by %s: %s\n' "$HOME" "$(id -un)" "$foreign"
  fail=$((fail + 1))
fi

# Registry and git reach the volume through symlinks, because cargo cannot be
# told to put the registry anywhere but $CARGO_HOME/registry. Were they real
# directories again, only target/ would survive a container.
cache_root=$(dirname "${CARGO_TARGET_BASE:-/nonexistent}")
for link in "$HOME/.cargo/registry" "$HOME/.cargo/git" "$HOME/.rustup/toolchains" "$HOME/.rustup/tmp"; do
  resolved=$(readlink -f "$link" 2>/dev/null || true)
  case "$resolved" in
    "$cache_root"/*)
      printf '  ok    %-22s -> %s\n' "$(basename "$link")" "$resolved"
      pass=$((pass + 1))
      ;;
    *)
      printf '  FAIL  %-22s resolves to %s, outside %s\n' \
        "$(basename "$link")" "${resolved:-nothing}" "$cache_root"
      fail=$((fail + 1))
      ;;
  esac
done

# rustup installs by renaming out of its tmp directory, which fails across
# filesystems.
tmp_dev=$(stat -L -c %d "$HOME/.rustup/tmp" 2>/dev/null)
tc_dev=$(stat -L -c %d "$HOME/.rustup/toolchains" 2>/dev/null)
if [ -n "$tmp_dev" ] && [ "$tmp_dev" = "$tc_dev" ]; then
  printf '  ok    %-22s same filesystem as toolchains\n' "rustup tmp"
  pass=$((pass + 1))
else
  printf '  FAIL  %-22s device %s, toolchains on %s\n' "rustup tmp" "${tmp_dev:-?}" "${tc_dev:-?}"
  fail=$((fail + 1))
fi

# The image's toolchains are reached through the volume but stored outside it,
# so a stale volume cannot pin them to an older image.
for tc in "$HOME"/.rustup/toolchains/*; do
  [ -e "$tc" ] || continue
  resolved=$(readlink -f "$tc" 2>/dev/null || true)
  case "$resolved" in
    /opt/rust/toolchains/*)
      printf '  ok    %-22s -> %s\n' "$(basename "$tc")" "$resolved"
      pass=$((pass + 1))
      ;;
    *)
      printf '  FAIL  %-22s resolves to %s, not /opt/rust/toolchains\n' \
        "$(basename "$tc")" "${resolved:-nothing}"
      fail=$((fail + 1))
      ;;
  esac
done

echo
echo "== project integration =="
# Proves it is on PATH, executable, and that the makefile parses.
require "rust-dev" rust-dev info

# Without it, an agent in the container has no way to learn about rust-dev.
if [ -r /etc/claude-code/CLAUDE.md ] && grep -q 'rust-dev' /etc/claude-code/CLAUDE.md; then
  printf '  ok    %-22s %s\n' "agent memory" /etc/claude-code/CLAUDE.md
  pass=$((pass + 1))
else
  printf '  FAIL  %-22s /etc/claude-code/CLAUDE.md missing or unreadable\n' "agent memory"
  fail=$((fail + 1))
fi

# dprint's YAML output must satisfy the image's yamllint config.
yaml_dir=$(mktemp -d)
printf -- '---\na: 1  # comment\n' >"$yaml_dir/t.yaml"
if (cd "$yaml_dir" && dprint fmt --config "$HOME/.config/dprint/dprint.jsonc" >/dev/null 2>&1 \
  && yamllint --strict t.yaml >/dev/null 2>&1); then
  printf '  ok    %-22s dprint output passes yamllint\n' "yaml config"
  pass=$((pass + 1))
else
  printf '  FAIL  %-22s dprint output fails yamllint\n' "yaml config"
  fail=$((fail + 1))
fi
rm -rf "$yaml_dir"

echo
echo "== end-to-end build =="
# Catches what version probes cannot: a toolchain that reports a version but
# cannot link, or a target dir the build user cannot write into.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if cargo new --quiet --lib "$work/smoke" >/dev/null 2>&1 \
  && (cd "$work/smoke" && cargo build --quiet --offline >/dev/null 2>&1) \
  && (cd "$work/smoke" && cargo nextest run --offline >/dev/null 2>&1); then
  printf '  ok    %-22s cargo new + build + nextest run\n' "compile+test"
  pass=$((pass + 1))
else
  printf '  FAIL  %-22s cargo new + build + nextest run\n' "compile+test"
  fail=$((fail + 1))
fi

# Offline, so it fails if the image did not come with a prebuilt Miri sysroot.
if [ -n "${MIRI_TOOLCHAIN:-}" ]; then
  if (cd "$work/smoke" && cargo "+$MIRI_TOOLCHAIN" miri test --offline >/dev/null 2>&1); then
    printf '  ok    %-22s cargo miri test, offline\n' "miri test"
    pass=$((pass + 1))
  else
    printf '  FAIL  %-22s cargo miri test, offline\n' "miri test"
    fail=$((fail + 1))
  fi
fi

# Bare cargo must land in a subdirectory of the base via the image's cargo
# config: never ./target on the repo mount, never the base `cargo clean` wipes.
effective=$(cd "$work/smoke" && cargo metadata --format-version 1 --no-deps 2>/dev/null \
  | yq -p json -r '.target_directory' 2>/dev/null)
case "$effective" in
  "${CARGO_TARGET_BASE:-/nonexistent}"/?*)
    printf '  ok    %-22s %s\n' "bare-cargo target" "$effective"
    pass=$((pass + 1))
    ;;
  *)
    printf '  FAIL  %-22s expected a subdirectory of %s, got %s\n' \
      "bare-cargo target" "${CARGO_TARGET_BASE:-unset}" "${effective:-none}"
    fail=$((fail + 1))
    ;;
esac

# rust-dev must override that with the crate name.
key=$(cd "$work/smoke" && rust-dev info 2>/dev/null | awk '/^cache key:/ {print $3}')
if [ "$key" = "smoke" ]; then
  printf '  ok    %-22s derived cache key = %s\n' "rust-dev key" "$key"
  pass=$((pass + 1))
else
  printf '  FAIL  %-22s expected \"smoke\", got \"%s\"\n' "rust-dev key" "$key"
  fail=$((fail + 1))
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "smoke test passed ($pass checks)"
else
  echo "smoke test FAILED ($fail failed, $pass passed)" >&2
fi
exit $((fail > 0))
