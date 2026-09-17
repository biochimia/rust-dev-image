#!/usr/bin/env bash
set -euo pipefail

VENDOR_DIR='image/vendor'
MANIFEST="${VENDOR_DIR}/vendor-manifest.txt"

declare -i errors=0
new_manifest=

function usage() {
  cat <<EOF
Usage: $0 [command]

Manages local vendored copies of upstream sources. Check sources list at ${MANIFEST}.

Commands:
  help          Show this usage message.

  check         Check content hashes of local vendored copies.

  fetch         Check local vendored copies, and fetch any missing or
                mismatched copies.

  force-fetch   Fetch all upstream copies (pre-existing local vendored copies
                are overwritten)

  update        Checks Github for updated project releases (where applicable)
EOF
}

function check-file-hash() {
  local name="$1"
  local file="$2"
  local hash="$3"

  local actual
  actual=$(file-hash "${file}")

  if [ "${actual}" != "${hash}" ]; then
    echo "SHA-256 digest mismatch for ${name} (${actual} != ${hash})." >&2
    return 1
  fi
}

declare -A _latest_github_release
function check-latest-github-release() {
  local re='^https://github\.com/([^/]+/[^/]+)/releases/download/([^/]+)/([^/]+)$'

  local name="$1"
  local source="$2"
  local target="$3"
  local hash="$4"
  local mode="$5"
  local rest="$6"

  if [[ "${source}" =~ $re ]]; then
    local project="${BASH_REMATCH[1]}"
    local version="${BASH_REMATCH[2]}"
    local asset_name="${BASH_REMATCH[3]}"

    if [[ ! -v _latest_github_release["${project}"] ]]; then
      _latest_github_release["${project}"]=$(curl -fsSL "https://api.github.com/repos/${project}/releases/latest")
    fi

    latest=$(yq -p json -o t .tag_name <<<"${_latest_github_release["${project}"]}")
    if [ "${version}" != "${latest}" ] || [ -z "${hash}" ]; then
      asset_url=$(
        ASSET_NAME="${asset_name}" \
          yq -p json -o t \
          '.assets[] | select(.name == strenv(ASSET_NAME)) | .browser_download_url' \
          <<<"${_latest_github_release["${project}"]}"
      )

      if [ -z "${asset_url}" ]; then
        echo "GitHub project ${project} updated upstream (${version} -> ${latest}), but is missing asset ${asset_name}." >&2
      else
        asset_ts=$(
          ASSET_NAME="${asset_name}" \
            yq -p json -o t \
            '.assets[] | select(.name == strenv(ASSET_NAME)) | .updated_at' \
            <<<"${_latest_github_release["${project}"]}"
        )
        asset_ts="${asset_ts/T/ }"
        asset_ts="${asset_ts%Z} UTC"

        asset_hash=$(
          ASSET_NAME="${asset_name}" \
            yq -p json -o t \
            '.assets[] | select(.name == strenv(ASSET_NAME)) | .digest' \
            <<<"${_latest_github_release["${project}"]}"
        )
        asset_hash="${asset_hash#sha256:}"
        { [ -n "${asset_hash}" ] && [ "${asset_hash}" != null ]; } ||
          asset_hash=

        source="${asset_url}"
        hash="${asset_hash}"
        rest="${asset_ts}"

      fi
    fi
  fi
  write-manifest "${name}" "${source}" "${target}" "${hash}" "${mode}" "${rest}"
}

function check-local() {
  local name="$1"
  local file="$2"
  local hash="$3"

  [ -f "${file}" ] || {
    echo "WARN: missing ${name}." >&2
    return 1
  }

  [ -n "${hash}" ] || {
    echo "WARN: missing content hash for ${name}, unable to verify." >&2
    return 2
  }

  check-file-hash "${name}" "${file}" "${hash}" || {
    echo "WARN: bad ${name}." >&2
    return 3
  }
}

function fetch-upstream() {
  local src="$1"
  local dst="$2"
  local hash="$3"
  local mode="$4"

  echo "INFO: fetching ${src}." >&2

  local dstdir
  dstdir=$(dirname "${dst}")
  mkdir -p "${dstdir}"

  local tmp
  tmp=$(mktemp -p "${dstdir}")
  trap '[ -f "${tmp}" ] && rm -f "${tmp}"' RETURN

  curl -fsSL --proto '=https' "${src}" -o "${tmp}" || {
    echo "ERROR: failed to fetch ${src}" >&2
    return 1
  }

  if [ -n "${hash}" ]; then
    check-file-hash "file fetched from ${src}" "${tmp}" "${hash}" ||
      return 2
  fi

  rotate-file "${tmp}" "${dst}" "${mode}"
  trap - RETURN
}

function file-hash() {
  sha256sum "$1" | cut -d' ' -f1
}

function rotate-file() {
  local src="$1"
  local dst="$2"
  local mode="$3"

  mv "${src}" "${dst}"
  chmod "${mode}" "${dst}"
}

function write-manifest() {
  local name="$1"
  local source="$2"
  local target="$3"
  local hash="${4:-}"
  local mode="${5:-0644}"

  shift 5

  local rest="$*"
  if [ -n "${rest}" ]; then
    rest="  ${rest}"
  fi

  printf "%-32s  %-120s  %-32s  %-64s  %8s%s\n" "${name}" "${source}" "${target}" "${hash}" "${mode}" "${rest}" >>"${new_manifest:-/dev/null}"
}

function write-manifest-header() { write-manifest "# name" source target "content hash (SHA-256)" filemode; }

action="${1:-check}"

update_manifest=false
check_local=false
check_latest_upstream=false
fetch_upstream=false

case "${action}" in
check)
  check_local=true
  ;;

fetch)
  update_manifest=true
  check_local=true
  fetch_upstream=true
  ;;

force-fetch)
  update_manifest=true
  fetch_upstream=true
  ;;

update)
  update_manifest=true
  check_latest_upstream=true
  ;;

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

if [ "${update_manifest}" = true ]; then
  new_manifest=$(mktemp -p "${VENDOR_DIR}")

  trap 'if [ -n "${new_manifest}" ] && [ -f "${new_manifest}" ]; then rm -f "${new_manifest}" || true; fi' ERR HUP INT TERM
  trap '[ -f "${new_manifest}" ] && rotate-file "${new_manifest}" "${MANIFEST}" 0644' EXIT

  write-manifest-header
fi

while read -r name source target hash mode rest; do
  [[ -z $name || $name == \#* ]] && continue

  mode="${mode:-0644}"
  dest="${VENDOR_DIR}/${target}"

  if [ "${check_latest_upstream}" = true ]; then
    check-latest-github-release "${name}" "${source}" "${target}" "${hash}" "${mode}" "${rest}"
    continue
  fi

  if [ "${check_local}" = true ] &&
    check-local "local copy of ${name}" "${dest}" "${hash}"; then
    write-manifest "${name}" "${source}" "${target}" "${hash}" "${mode}" "${rest}"
  elif [ "${fetch_upstream}" = true ] &&
    fetch-upstream "${source}" "${dest}" "${hash}" "${mode}"; then
    ts=$(date -u '+%Y-%m-%d %H:%M:%S %Z')

    if [ -z "${hash}" ]; then
      rest="${ts}"
      hash=$(file-hash "${dest}")
      echo "WARN: ${name} has no upstream digest; pinned our own download." >&2
    fi

    write-manifest "${name}" "${source}" "${target}" "${hash}" "${mode}" "${rest:-"${ts}"}"
  else
    errors=$((errors + 1))
  fi
done <"${MANIFEST}"

[ 0 -eq "${errors}" ]
