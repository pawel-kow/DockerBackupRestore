# Docker Container & Volume Backup and Restore Scripts

A set of two powerful `bash` scripts to simplify the process of creating complete, portable backups of your Docker containers and restoring them on any machine.

These scripts handle everything: the container's image, its named volumes, and its exact configuration, including environment variables, port mappings, and restart policies.

---

## Features

-   **Complete Container Backup**: Creates a backup of the container's image using `docker commit` and saves it as a compressed (`.tar.gz`) archive.
-   **Full Volume Backup**: Identifies all named volumes attached to a container and archives their contents into individual `.tar.gz` files.
-   **Organized Structure**: All volume backups are neatly stored in a dedicated `volumes/` subdirectory to prevent naming conflicts.
-   **Configuration Save**: Saves the container's full configuration (from `docker inspect`) into a `container_config.json` file for perfect restoration.
-   **Automated Restore**: The restore script reads the backup directory and automatically:
    -   Loads the container image.
    -   Restores all volume data into new Docker volumes from the `volumes/` subdirectory.
    -   Recreates the container with its **original name** and configuration.
-   **Intelligent Checks**:
    -   Checks for dependencies like `jq`.
    -   Avoids re-loading a Docker image if it already exists.
    -   Warns you if a container or volume with the same name already exists before restoring.
    -   Verifies that local paths for **bind mounts** exist on the new machine before attempting to start the container.
-   **Portability**: The backup directory is self-contained and can be easily moved to another machine for disaster recovery or migration.

---

## Prerequisites

Before using these scripts, please ensure you have the following installed on both the source and destination machines:

1.  **Docker**: The scripts rely on the Docker engine to manage containers, volumes, and images.
2.  **Bash**: The scripts are written in `bash`.
3.  **jq**: A lightweight and flexible command-line JSON processor. This is required by the restore script to parse the container's configuration.
    -   **Debian/Ubuntu**: `sudo apt-get install jq`
    -   **macOS (Homebrew)**: `brew install jq`
    -   **Red Hat/CentOS**: `sudo yum install jq`

---

## Usage

### 1\. Backing Up a Container

Run the `backup_docker.sh` script with the name or ID of the container you wish to back up.

```bash
./backup_docker.sh <container_name_or_id>
```

**Example:**

```bash
./backup_docker.sh my_postgres_db
```

This will create a new directory named `backup_my_postgres_db_YYYYMMDD_HHMMSS` with the following structure:

```
backup_my_postgres_db_20250807_223000/
├── container_image.tar.gz
├── container_config.json
└── volumes/
    ├── volume_one.tar.gz
    └── volume_two.tar.gz
```

### 2\. Restoring a Container

1.  Copy the entire backup directory to the target machine.
2.  Run the `restore_docker.sh` script, pointing it to the backup directory.

<!-- end list -->

```bash
./restore_docker.sh <path_to_backup_directory>
```

**Example:**

```bash
./restore_docker.sh backup_my_postgres_db_20250807_223000
```

The script will handle the rest, leaving you with a perfectly restored container running under its original name.

-----

## Important Notes

  - **Existing Containers**: The restore script will fail if a container with the same name already exists on the target machine. You must manually remove it (`docker rm <container_name>`) before running the restore script.
  - **Bind Mounts**: If your original container used bind mounts (mounting a local directory from the host), you **must ensure those directories exist** on the target machine at the exact same path. The restore script will check for these paths and exit with an error if they are not found.
  - **Root/Sudo**: Depending on your Docker installation, you may need to run these scripts with `sudo`.

<!-- end list -->
