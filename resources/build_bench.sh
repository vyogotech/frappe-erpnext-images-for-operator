#!/bin/bash
set -ex

# This script initializes the Frappe Bench and installs apps.
# It is designed to run inside the Docker builder container.

# CRITICAL: Disable 'uv' for Docker builds. 'uv' often crashes with
# Illegal Instruction (exit 167) during emulated ARM64 builds in QEMU.
export BENCH_USE_UV=0
export INSTALL_USE_UV=0
export PYTHON_PATH="./env/bin/python"

# Ensure we are NOT using uv
if command -v uv >/dev/null 2>&1; then
    echo "WARNING: uv found in PATH, attempting to hide it..."
    # We don't want to fail if it's there but ignored, but we want to know
fi

BENCH_DIR="/home/frappe/frappe-bench"

# 1. Setup Git
git config --global user.email "frappe@example.com"
git config --global user.name "frappe"
git config --global --add safe.directory '*'

# 2. Ensure clean start
echo "Cleaning target directory: $BENCH_DIR"
rm -rf "$BENCH_DIR"

# 3. Initialize Bench
echo "Starting bench init..."
bench init \
    --frappe-branch="${FRAPPE_BRANCH:-version-15}" \
    --frappe-path="${FRAPPE_PATH:-https://github.com/frappe/frappe}" \
    --no-procfile \
    --no-backups \
    --skip-redis-config-generation \
    --verbose \
    "$BENCH_DIR"

# 4. Enter bench directory and FORCE-DISABLE UV
cd "$BENCH_DIR"
echo "Disabling uv via bench config..."
# Many modern bench versions will ignore ENV if config is present
./env/bin/pip uninstall -y uv || true
bench config use_uv off || true

# 5. Fetch Apps
echo "Starting app discovery..."
export GITHUB_TOKEN="${GH_BUILD_KEY}"
APPS_LIST=$(get_apps --org "${GITHUB_ORG}" --apps "${APPS} ${ERPNEXT_REPO}")

if [ -n "$APPS_LIST" ]; then
    echo "Identified unique apps to install: $APPS_LIST"
    for app_item in $APPS_LIST; do
        if [[ "$app_item" == *"#"* ]]; then
            app_name="${app_item%%#*}"
            app_url="${app_item##*#}"
            echo "Installing app $app_name from $app_url"
            # Use safer [name] [url] format
            bench get-app --resolve-deps --branch "${FRAPPE_BRANCH:-version-15}" "$app_name" "$app_url"
        else
            app_name="$app_item"
            echo "Installing app $app_name"
            bench get-app --resolve-deps --branch "${FRAPPE_BRANCH:-version-15}" "$app_name"
        fi

        # LOGGING: Verify checkout branch
        if [ -d "apps/$app_name" ]; then
            echo "Branch verification for $app_name:"
            git -C "apps/$app_name" branch
        fi
    done
else
    echo "No custom apps to install."
fi

# 6. Build Assets
echo "Finalizing site config and building assets..."
echo "{}" > sites/common_site_config.json
bench build

# 7. Final Cleanup
echo "Cleaning up build artifacts..."
rm -rf apps/*/.git
find . -name "__pycache__" -type d -exec rm -rf {} +
find . -name "*.pyc" -delete

echo "Build script completed successfully!"
