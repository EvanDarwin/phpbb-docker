#!/bin/sh
# Run the container test suite.
#
#   tests/run.sh                         # every tests/test_*.sh
#   tests/run.sh tests/test_security.sh  # just these
#
# Builds the image under test (PHPBB_VERSION, default 3.3.19) and an older one for
# the upgrade and downgrade tests (OLD_PHPBB_VERSION, default 3.3.15), unless
# IMAGE / OLD_IMAGE name existing images. Needs docker and network access: the
# builds download phpBB, and the upgrade tests start from the last published
# image and pull mariadb:11.
set -u
cd "$(dirname "$0")/.."

build() {
  echo "Building $1 (phpBB $2)..."
  docker build -q --build-arg PHPBB_VERSION="$2" -t "$1" . >/dev/null || { echo "Build of $1 failed"; exit 1; }
}
if [ -z "${IMAGE:-}" ]; then
  IMAGE=phpbb-test:${PHPBB_VERSION:-3.3.19}
  build "$IMAGE" "${PHPBB_VERSION:-3.3.19}"
fi
if [ -z "${OLD_IMAGE:-}" ]; then
  OLD_IMAGE=phpbb-test:${OLD_PHPBB_VERSION:-3.3.15}
  build "$OLD_IMAGE" "${OLD_PHPBB_VERSION:-3.3.15}"
fi
export IMAGE OLD_IMAGE

# Pull the external images up front so their progress output stays out of the results
echo "Pulling the last published image and mariadb:11..."
LEGACY_IMAGE=$(sed -n 's/^LEGACY_IMAGE="\(.*\)"$/\1/p' tests/lib.sh)
docker pull -q "$LEGACY_IMAGE" >/dev/null && docker pull -q mariadb:11 >/dev/null || { echo "Pull failed"; exit 1; }

[ $# -gt 0 ] || set -- tests/test_*.sh
failed_files=""
for test_file in "$@"; do
  echo
  echo "=== $test_file"
  sh "$test_file" || failed_files="$failed_files $test_file"
done

echo
if [ -n "$failed_files" ]; then
  echo "FAILED:$failed_files"
  exit 1
fi
echo "All tests passed"
