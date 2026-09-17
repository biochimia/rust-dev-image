#!/bin/bash
set -euo pipefail

# crates.io requires a custom user agent for API calls
USER_AGENT="github.com/biochimia/rust-dev-image/$(basename "$0")"

VERSIONS_MK="versions.mk"

declare -i behind=0

function usage() {
  cat <<USAGE
Usage: $0 [command]

Compares the crate versions pinned in ${VERSIONS_MK} against crates.io.

Commands:
  help      Show this usage message.

  check     Report pinned crates with a newer release. Default.

  update    Rewrite ${VERSIONS_MK} with the newest release of each crate.
USAGE
}

function fetch() {
  curl -fsSL -H "User-Agent: ${USER_AGENT}" "$1"
}

function latest-crate-version() {
  fetch "https://crates.io/api/v1/crates/$1" |
    yq -p json -o t .crate.max_stable_version
}

function pinned-crate-versions() {
  awk -F '[[:space:]]*[?]=[[:space:]]*' '
  /^[[:space:]]*(#|$)/ { next }

  $1 ~ /_VERSION$/ {              # CARGO_BLOAT_VERSION
    crate = tolower($1)           # cargo_bloat_version
    sub(/_version$/, "", crate)   # cargo_bloat
    gsub(/_/, "-", crate)         # cargo-bloat

    print $1, crate, $2
  }
  ' "${VERSIONS_MK}"
}

# Preserve the file's column alignment rather than reflowing it.
function set-pinned-version() {
  local name="$1"
  local version="$2"

  sed -i.bak "s|^\(${name}[[:space:]]*?=[[:space:]]*\).*|\1${version}|" "${VERSIONS_MK}" && rm -f "${VERSIONS_MK}.bak"
}

action="${1:-check}"

case "${action}" in
check | update) ;;

help)
  usage
  exit
  ;;

*)
  echo "Unrecognized action '${action}'" >&2
  usage >&2
  exit 1
  ;;
esac

while read -r name crate version; do
  latest=$(latest-crate-version "${crate}")

  if [ -z "${latest}" ] || [ "${latest}" = null ]; then
    echo "WARN: could not resolve a version for ${crate}." >&2
    continue
  fi

  [ "${version}" != "${latest}" ] || continue

  behind+=1

  if [ update = "${action}" ]; then
    set-pinned-version "${name}" "${latest}"
    echo "Updated ${crate}: ${version} -> ${latest}"
  else
    echo "Crate ${crate} updated upstream: ${version} -> ${latest}"
  fi
done < <(pinned-crate-versions)

if [ 0 -eq "${behind}" ]; then
  echo "All pinned crates are current."
elif [ update = "${action}" ]; then
  echo "Review the diff: git diff ${VERSIONS_MK}"
fi
