#!/usr/bin/env bash
# common.sh - packaging environment for Lolor.
#
# Lolor is a PostgreSQL extension: one build per PG major.
# pgedge-detect-build-matrix reads this to fan the matrix out over pg_versions.
PER_PG_VERSION=true

export PG_VERSION="${PG_VERSION:-17}"
export PG_MAJOR_VERSION="$(echo "$PG_VERSION" | cut -d. -f1)"

export PG_LOLOR_REPO="https://github.com/pgEdge/lolor.git"
export LOLOR_BRANCH="${COMPONENT_BRANCH:-v1.3.0}"

# Upstream version, suffix-stripped (e.g. 1.3.0). Names the source tarball's
# internal directory and the RPM Version.
export LOLOR_VERSION="${COMPONENT_VERSION:-1.3.0}"
export LOLOR_BUILDNUM=${COMPONENT_BUILDNUM:-1}

export REPO_TYPE="${REPO_TYPE:-daily}"

# DEB only: move a pre-release pretag (COMPONENT_BUILDNUM='rc1_1') into the
# upstream version with a leading '~' so pre-releases sort BELOW stable in
# dpkg/reprepro: 1.3.0~rc1-1.noble < 1.3.0-1.noble.
#
# The '~' form goes in a SEPARATE variable used only by the debian/changelog:
# LOLOR_VERSION itself must stay clean because it names the source tarball
# and its unpack directory (a '~' there would break %setup and the DEB extract).
export LOLOR_DEB_VERSION="${LOLOR_VERSION}"
if command -v apt-get &>/dev/null; then
    if [[ "$LOLOR_BUILDNUM" == *_* ]]; then
        LOLOR_PRETAG="${LOLOR_BUILDNUM%%_*}"
        export LOLOR_DEB_VERSION="${LOLOR_VERSION}~${LOLOR_PRETAG}"
        LOLOR_BUILDNUM="${LOLOR_BUILDNUM##*_}"
    fi
fi

# release.yml stages the source tarball built from THIS run's checkout here.
export ARTIFACT_DIR="${ARTIFACT_DIR:-$(pwd)/release-artifacts}"
export SRC_TARBALL="lolor-${LOLOR_VERSION}.tar.gz"

# Prefer the workflow-staged tarball (so branch / simulate_tag runs build the
# exact commit under test and need no network). The LOLOR_BRANCH clone is an
# opt-in fallback for local builds: set LOLOR_ALLOW_CLONE_FALLBACK=1.
stage_source() {
  local dest="$1"
  if [ -f "${ARTIFACT_DIR}/${SRC_TARBALL}" ]; then
    echo "Staging ${SRC_TARBALL} from ${ARTIFACT_DIR}"
    cp "${ARTIFACT_DIR}/${SRC_TARBALL}" "${dest}"
  elif [ -z "${LOLOR_ALLOW_CLONE_FALLBACK:-}" ]; then
    # A staged tarball is required by default: cloning LOLOR_BRANCH instead
    # would ship a package built from a different commit than COMPONENT_VERSION
    # claims.
    echo "::error::${ARTIFACT_DIR}/${SRC_TARBALL} not found. release.yml stages it with git archive; for a local build, stage it yourself or set LOLOR_ALLOW_CLONE_FALLBACK=1 to clone ${LOLOR_BRANCH} instead." >&2
    return 1
  else
    echo "Fetching Lolor source code (${LOLOR_BRANCH})"
    rm -rf "lolor-${LOLOR_VERSION}"
    git clone --depth=1 --branch "$LOLOR_BRANCH" "$PG_LOLOR_REPO" "lolor-${LOLOR_VERSION}"
    rm -rf "lolor-${LOLOR_VERSION}/.git"
    tar -czf "${SRC_TARBALL}" "lolor-${LOLOR_VERSION}"
    rm -rf "lolor-${LOLOR_VERSION}"
    mv "${SRC_TARBALL}" "${dest}"
  fi
}
