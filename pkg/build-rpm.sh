#!/bin/bash
set -euo pipefail

RHEL="$(rpm --eval %rhel)"

prepare() {
  setup_dnf_build_env
  echo "Copying packaging files..."
  cp ${COMPONENT_NAME}/rpm/lolor.spec ~/rpmbuild/SPECS/

  # The spec's Source0 basename is v<version>.tar.gz (a GitHub tag archive),
  # while %setup expects the lolor-<version>/ directory inside it — which is
  # what release.yml's `git archive --prefix` produces.
  stage_source ~/rpmbuild/SOURCES/v${LOLOR_VERSION}.tar.gz

  # This function is for debugging purpose if you have your own keys. GH workflow sets it
  #import_gpg_keys

  echo "🔧 Installing RPM build dependencies..."
  dnf builddep -y \
    --define "lolor_version ${LOLOR_VERSION}" \
    --define "lolor_buildnum ${LOLOR_BUILDNUM}" \
    --define "pgmajorversion ${PG_MAJOR_VERSION}" \
    ~/rpmbuild/SPECS/lolor.spec
}

build() {
  QA_RPATHS=$(( 0xffff )) rpmbuild -ba ~/rpmbuild/SPECS/lolor.spec \
    --define "lolor_version ${LOLOR_VERSION}" \
    --define "lolor_buildnum ${LOLOR_BUILDNUM}" \
    --define "pgmajorversion ${PG_MAJOR_VERSION}"
}

post_build() {
  echo "📤 Copying built RPMs to /output..."
  mkdir -p /output
  cp -v ~/rpmbuild/RPMS/*/*.rpm /output/ || echo "No binary RPMs found"
  cp -v ~/rpmbuild/SRPMS/*.src.rpm /output/ || echo "No SRPM found"

  sign_rpms /output/*.rpm
  validate_signatures /output/*.rpm
}
