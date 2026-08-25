#!/bin/sh
set -eu

kernel_version=${KVER:-6.12}
exec vng -v -r "v${kernel_version}" -- bundle exec rake test:system
