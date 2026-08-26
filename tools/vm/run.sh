#!/bin/sh
set -eu

cd -- "$(dirname -- "$0")/../.."

kernel_version=${KVER:-6.12.20}
bundle exec rake compile

set -- env MOUNTFD_SYSTEM=1 MOUNTFD_MATRIX=1 RSPEC_STATUS_PATH=/tmp/mountfd-rspec-status
if [ -n "${GEM_HOME:-}" ]; then
  set -- "$@" "GEM_HOME=$GEM_HOME" "GEM_PATH=${GEM_PATH:-$GEM_HOME}"
fi
set -- "$@" bundle exec rspec spec/system/mountfd_system_spec.rb

case "$kernel_version" in
  5.10*) exec vng -v -r "v${kernel_version}" -a psi=0 -- "$@" ;;
  *) exec vng -v -r "v${kernel_version}" -- "$@" ;;
esac
