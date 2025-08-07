#!/bin/bash

#==============================================================================
# Docker Volume and Container Restore Script
#
# This script restores a Docker container image, its associated volumes,
# and then automatically recreates the container using the restored assets
# under its original name. It also handles local bind mounts, ensuring the
# source paths exist on the host.
#
# It requires 'jq' to be installed for parsing the container's configuration.
#
# Usage:
#   ./restore_docker.sh <path_to_backup_directory>
#
# Example:
#   ./restore_docker.sh backup_my_web_app_20250807_211500
#
#==============================================================================

# --- Configuration ---
# Exit immediately if a command exits with a non-zero status.
set -e

# --- Dependency Check ---
# Check if jq is installed, as it's required for parsing the config file.
if ! command -v jq &> /dev/null; then
    echo "Error: 'jq' is not installed, but it is required to parse the container configuration." >&2
    echo "Please install it to continue." >&2
    echo "  - On Debian/Ubuntu: sudo apt-get install jq" >&2
    echo "  - On macOS (Homebrew): brew install jq" >&2
    echo "  - On Red Hat/CentOS: sudo yum install jq" >&2
    exit 1
fi

# --- Input Validation ---
# Check if the backup directory path is provided.
if [ -z "$1" ]; then
  echo "Error: No backup directory path provided."
  echo "Usage: $0 <path_to_backup_directory>"
  exit 1
fi

BACKUP_DIR=$1

# --- Pre-flight Checks ---
# Check if the backup directory and necessary files exist.
if [ ! -d "$BACKUP_DIR" ]; then
  echo "Error: Backup directory '${BACKUP_DIR}' not found."
  exit 1
fi

IMAGE_ARCHIVE="${BACKUP_DIR}/container_image.tar.gz"
if [ ! -f "$IMAGE_ARCHIVE" ]; then
    echo "Error: Container image backup 'container_image.tar.gz' not found in '${BACKUP_DIR}'."
    exit 1
fi

CONFIG_FILE="${BACKUP_DIR}/container_config.json"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Error: Container configuration 'container_config.json' not found in '${BACKUP_DIR}'."
    exit 1
fi


# --- Restore Process ---
echo "Starting restore from directory '${BACKUP_DIR}'..."

# --- Container Image Restore ---
echo "--------------------------------------------------"
echo "Checking container image status..."

# Extract the image name from the gzipped archive's manifest without loading the whole archive.
IMAGE_NAME_IN_ARCHIVE=$(tar -zxOf "${IMAGE_ARCHIVE}" manifest.json | jq -r '.[0].RepoTags[0]')

# Check if the image already exists locally.
if docker image inspect "${IMAGE_NAME_IN_ARCHIVE}" &> /dev/null; then
    echo "Image '${IMAGE_NAME_IN_ARCHIVE}' already exists locally. Skipping load."
    LOADED_IMAGE="${IMAGE_NAME_IN_ARCHIVE}"
else
    echo "Restoring container image from ${IMAGE_ARCHIVE}..."
    # Decompress the gzipped archive and pipe it to 'docker load'.
    LOADED_IMAGE=$(gunzip -c "${IMAGE_ARCHIVE}" | docker load | sed -n 's/Loaded image: //p')
    if [ -z "$LOADED_IMAGE" ]; then
        LOADED_IMAGE=$(gunzip -c "${IMAGE_ARCHIVE}" | docker load | awk -F ' ' '{print $3}' | head -n 1)
    fi
    echo "Successfully loaded image: ${LOADED_IMAGE}"
fi


# --- Volume Restore ---
VOLUME_BACKUP_DIR="${BACKUP_DIR}/volumes"
if [ ! -d "$VOLUME_BACKUP_DIR" ] || ! ls "${VOLUME_BACKUP_DIR}"/*.tar.gz &> /dev/null; then
    echo "Warning: No volume backups found in '${VOLUME_BACKUP_DIR}'. Skipping volume restore."
else
    for backup_file in "${VOLUME_BACKUP_DIR}"/*.tar.gz; do
        VOLUME_NAME=$(basename "${backup_file}" .tar.gz)
        echo "--------------------------------------------------"
        echo "Restoring volume: ${VOLUME_NAME}"

        if docker volume ls -q -f name="^${VOLUME_NAME}$" | grep -q .; then
            echo "Warning: Volume '${VOLUME_NAME}' already exists. Skipping creation."
        else
            echo "Creating new volume: ${VOLUME_NAME}"
            docker volume create "${VOLUME_NAME}"
        fi

        docker run --rm \
            -v "${VOLUME_NAME}":/volume_data \
            -v "$(cd "${VOLUME_BACKUP_DIR}" && pwd)":/backup_target:ro \
            ubuntu \
            tar xzf "/backup_target/$(basename ${backup_file})" -C /volume_data
        echo "Successfully restored data to volume '${VOLUME_NAME}'"
    done
fi


# --- Container Recreation ---
echo "--------------------------------------------------"
echo "Recreating container from configuration..."

CONFIG_JSON=$(cat "${CONFIG_FILE}")
ORIGINAL_NAME=$(echo "$CONFIG_JSON" | jq -r '.[0].Name' | sed 's/^\///')

if docker ps -a --format '{{.Names}}' | grep -q "^${ORIGINAL_NAME}$"; then
    echo "Error: A container named '${ORIGINAL_NAME}' already exists. Please remove it before restoring."
    exit 1
fi

DOCKER_RUN_ARGS=("-d" "--name" "${ORIGINAL_NAME}")

RESTART_POLICY=$(echo "$CONFIG_JSON" | jq -r '.[0].HostConfig.RestartPolicy.Name')
if [ "$RESTART_POLICY" != "no" ] && [ ! -z "$RESTART_POLICY" ]; then
    DOCKER_RUN_ARGS+=("--restart=${RESTART_POLICY}")
fi

while IFS= read -r env_var; do
    DOCKER_RUN_ARGS+=("-e" "$env_var")
done < <(echo "$CONFIG_JSON" | jq -r '.[0].Config.Env[]')

while IFS= read -r port_map; do
    DOCKER_RUN_ARGS+=("-p" "$port_map")
done < <(echo "$CONFIG_JSON" | jq -r '.[0].HostConfig.PortBindings | to_entries[] | "\(.value[0].HostPort):\(.key | split("/")[0])"')

# Add restored Docker volumes
while IFS= read -r volume_map; do
    DOCKER_RUN_ARGS+=("-v" "$volume_map")
done < <(echo "$CONFIG_JSON" | jq -r '.[0].Mounts[] | select(.Type == "volume") | "\(.Name):\(.Destination)"')

# Add local bind mounts and verify they exist
echo "Verifying local bind mount paths..."
while IFS= read -r bind_mount_json; do
    SOURCE_PATH=$(echo "$bind_mount_json" | jq -r '.Source')
    DEST_PATH=$(echo "$bind_mount_json" | jq -r '.Destination')

    # Check if the source path exists on the host. It can be a file or a directory.
    if [ ! -f "$SOURCE_PATH" ] && [ ! -d "$SOURCE_PATH" ]; then
        echo "--------------------------------------------------"
        echo "‼️ ERROR: Missing Bind Mount Source Path"
        echo "The original container used a bind mount that points to a local path that does not exist on this machine."
        echo "Path: ${SOURCE_PATH}"
        echo "Please create this directory or file, or edit the script to proceed without this mount."
        exit 1
    fi
    echo "  ✅ Path exists: ${SOURCE_PATH}"
    DOCKER_RUN_ARGS+=("-v" "${SOURCE_PATH}:${DEST_PATH}")
done < <(echo "$CONFIG_JSON" | jq -c '.[0].Mounts[] | select(.Type == "bind")')


DOCKER_RUN_ARGS+=("$LOADED_IMAGE")

echo "--------------------------------------------------"
echo "Executing command to start the new container..."
printf "docker run %s\n" "${DOCKER_RUN_ARGS[*]}"

docker run "${DOCKER_RUN_ARGS[@]}"

echo "--------------------------------------------------"
echo "✅ Restore and recreation process completed successfully!"
echo "A new container named '${ORIGINAL_NAME}' has been started."
