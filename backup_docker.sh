#!/bin/bash

#==============================================================================
# Docker Volume and Container Backup Script
#
# This script backs up all volumes associated with a given Docker container,
# and also saves a compressed image of the container itself.
#
# It inspects the container to find its volumes, creates a compressed
# tarball for each volume inside a dedicated 'volumes' directory, commits
# the container to a new image, and saves that image to a gzipped tarball.
#
# Usage:
#   ./backup_docker.sh <container_name_or_id>
#
# Example:
#   ./backup_docker.sh my_postgres_container
#
#==============================================================================

# --- Configuration ---
# Exit immediately if a command exits with a non-zero status.
set -e

# --- Input Validation ---
# Check if the container name is provided as the first argument.
if [ -z "$1" ]; then
  echo "Error: No container name or ID provided."
  echo "Usage: $0 <container_name_or_id>"
  exit 1
fi

CONTAINER_NAME=$1
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_DIR="backup_${CONTAINER_NAME}_${TIMESTAMP}"

# --- Pre-flight Checks ---
# Check if the specified container exists and is running or stopped.
if ! docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
    echo "Error: Container '${CONTAINER_NAME}' not found."
    exit 1
fi

# --- Backup Process ---
echo "Starting backup for container '${CONTAINER_NAME}'..."

# Create dedicated directories for this backup.
mkdir -p "${BACKUP_DIR}/volumes"
echo "Backup directory created at: ./${BACKUP_DIR}"

# --- Volume Backup ---
# Get a list of all named volumes used by the container.
# This uses a standard Go template 'if' condition to ensure portability.
VOLUMES=$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}} {{end}}{{end}}' "${CONTAINER_NAME}")

# Check if the container has any named volumes.
if [ -z "$VOLUMES" ]; then
    echo "Warning: Container '${CONTAINER_NAME}' does not use any named volumes. Nothing to back up."
else
    echo "Found volumes: ${VOLUMES}"
    # Loop through each volume and back it up.
    for volume in $VOLUMES; do
        echo "--------------------------------------------------"
        echo "Backing up volume: ${volume}"
        docker run --rm \
            -v "${volume}":/volume_data:ro \
            -v "$(pwd)/${BACKUP_DIR}":/backup_target \
            ubuntu \
            tar czf "/backup_target/volumes/${volume}.tar.gz" -C /volume_data .
        echo "Successfully backed up volume '${volume}' to ./${BACKUP_DIR}/volumes/${volume}.tar.gz"
    done
fi


# --- Container Image Backup ---
echo "--------------------------------------------------"
echo "Backing up the container image..."

# Docker image names must be lowercase. Convert the container name.
LOWERCASE_CONTAINER_NAME=$(echo "${CONTAINER_NAME}" | tr '[:upper:]' '[:lower:]')
TEMP_IMAGE_NAME="${LOWERCASE_CONTAINER_NAME}_backup_img:${TIMESTAMP}"
IMAGE_FILENAME="${BACKUP_DIR}/container_image.tar.gz"

# Commit the container's filesystem to a new, temporary image.
# The -p flag pauses the container during commit to ensure data consistency.
echo "Committing container '${CONTAINER_NAME}' to a temporary image: ${TEMP_IMAGE_NAME}"
docker commit -p "${CONTAINER_NAME}" "${TEMP_IMAGE_NAME}"

# Save the new image to a gzipped tar archive.
# We pipe the output of 'docker save' to 'gzip' for compression.
echo "Saving and compressing image to ${IMAGE_FILENAME}"
docker save "${TEMP_IMAGE_NAME}" | gzip > "${IMAGE_FILENAME}"

# Clean up by removing the temporary image.
echo "Removing temporary image ${TEMP_IMAGE_NAME}"
docker rmi "${TEMP_IMAGE_NAME}"

echo "Successfully backed up container image."


# --- Finalization ---
# As a best practice, also save the container's configuration for reference.
echo "--------------------------------------------------"
echo "Saving container configuration..."
docker inspect "${CONTAINER_NAME}" > "${BACKUP_DIR}/container_config.json"
echo "Configuration saved to ./${BACKUP_DIR}/container_config.json"

echo "--------------------------------------------------"
echo "✅ Backup process completed successfully!"
echo "Backup data is located in: ./${BACKUP_DIR}"
