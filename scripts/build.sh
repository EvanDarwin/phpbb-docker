#!/bin/sh
# Using POSIX shell for better compatibility
set -e

# Custom echo function for consistent prefixing
log() {
  echo "[$(hostname)] $1"
}

# Debug function - only prints if DEBUG=true
debug() {
  if [ "${DEBUG:-false}" = "true" ]; then
    echo "[$(hostname)-debug] $1"
  fi
}

# Get latest phpBB version if not explicitly set
if [ -z "${PHPBB_VERSION}" ]; then
  log "Fetching latest phpBB release version from GitHub API..."
  
  # Fetch all releases with proper error handling
  RELEASES=$(curl -s -f -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/phpbb/phpbb/tags)
  
  # Check if curl was successful
  if [ $? -ne 0 ] || [ -z "$RELEASES" ]; then
    log "ERROR: Failed to fetch tags from GitHub API"
    log "You can specify a version manually with: PHPBB_VERSION=3.3.15 ./scripts/build.sh"
    exit 1
  fi
  
  debug "Raw API response size: $(echo "$RELEASES" | wc -c) bytes"
  
  # Extract valid version information without using jq
  log "Parsing GitHub API response for latest version"
  # Find all release tags, filter out RCs, and get the first one
  VERSION=$(echo "$RELEASES" | grep -o '"name": "release-[^"]*"' | 
             grep -v "RC" | 
             head -1 | 
             sed 's/"name": "release-//;s/"//g')
  
  if [ -z "$VERSION" ]; then
    log "ERROR: Failed to find a valid release version"
    log "Try running with DEBUG=true to see more information"
    log "You can specify a version manually with: PHPBB_VERSION=3.3.15 ./scripts/build.sh"
    exit 1
  fi
  
  log "Found release version: $VERSION"
else
  # Use provided version
  VERSION=${PHPBB_VERSION}
  log "Using provided version: $VERSION"
fi

if [ -z "$VERSION" ]; then
  log "ERROR: Failed to get a valid phpBB version"
  log "You can specify a version manually with: PHPBB_VERSION=3.3.15 ./scripts/build.sh"
  exit 1
fi

log "Selected phpBB version: $VERSION"

# Extract major, minor, and patch versions
MAJOR_VERSION=$(echo "$VERSION" | cut -d. -f1)
MINOR_VERSION=$(echo "$VERSION" | cut -d. -f1,2)
PATCH_VERSION=$VERSION

log "Version components: Major=$MAJOR_VERSION, Minor=$MINOR_VERSION, Patch=$PATCH_VERSION"

# Set image name base
DOCKER_IMAGE=${DOCKER_IMAGE:-"evandarwin/phpbb"}

# Build the Docker image with PHP 8.4
log "==> Building phpBB Docker image"
log "  phpBB version   :: $VERSION"
log "  PHP version     :: 8.4"
log "  Alpine version  :: edge"
log "  image name      :: $DOCKER_IMAGE:$VERSION"

# Set build args
BUILD_ARGS="--build-arg PHPBB_VERSION=$VERSION --build-arg PHP_VERSION=84 --build-arg ALPINE_VERSION=edge"

# Build the Docker image
docker build \
  $BUILD_ARGS \
  -t "$DOCKER_IMAGE:$VERSION" \
  .

# Create additional version tags
docker tag "$DOCKER_IMAGE:$VERSION" "$DOCKER_IMAGE:$MINOR_VERSION"
log "Tagged $VERSION as $MINOR_VERSION"

docker tag "$DOCKER_IMAGE:$VERSION" "$DOCKER_IMAGE:$MAJOR_VERSION"
log "Tagged $VERSION as $MAJOR_VERSION"

docker tag "$DOCKER_IMAGE:$VERSION" "$DOCKER_IMAGE:latest"
log "Tagged $VERSION as latest"

log "==> Build complete!"

# Display success message
log "==> All builds complete!"
log "To run the container: docker run -p 8080:8080 $DOCKER_IMAGE:<tag>"
log "Available tags: $VERSION, $MINOR_VERSION, $MAJOR_VERSION, latest"
