#!/bin/bash
# AppBuild pipeline core: git checkout -> fpm package -> validate -> (publish).
#
# Runs inside the fpm-builder image (frappe/build + fpm CLI), which provides a
# working node + yarn-classic + a scratch bench at /home/frappe/frappe-bench.
# The AppBuild controller sets the environment below and runs this as a Job.
#
# The point of this script is that the fragile work — cloning, `bench build`
# (assets), and vendoring the full transitive wheel closure — happens ONCE here,
# off the serving path, and the result is VALIDATED before it can be published.
# The two gaps found in the hand-built registry packages (no public/dist, an
# incomplete wheel set) are exactly what steps 2 + 4 fix and step 4 catches.
set -euo pipefail

# --- inputs (set by the AppBuild controller) ---
: "${APP_NAME:?APP_NAME required}"          # e.g. wiki
: "${ORG:?ORG required}"                     # e.g. frappe
: "${GIT_URL:?GIT_URL required}"             # https://github.com/frappe/wiki.git
: "${GIT_REF:?GIT_REF required}"             # branch / tag / commit
: "${VERSION:?VERSION required}"             # package version, e.g. 3.0.0
REGISTRY_URL="${REGISTRY_URL:-https://fpm.vyogo.tech}"  # to resolve required_apps
PLATFORM="${PLATFORM:-manylinux2014_x86_64}"           # target bench wheel platform
PY_VERSION="${PY_VERSION:-3.14}"                        # target bench python
BENCH="${BENCH_PATH:-/home/frappe/frappe-bench}"
WORK="${WORKDIR:-/workspace}"
PUBLISH="${PUBLISH:-false}"                             # only true once auth is wired
PUBLISH_REPO="${PUBLISH_REPO:-vyogo}"

mkdir -p "$WORK/src" "$WORK/out"

echo "==> [1/4] Clone $ORG/$APP_NAME @ $GIT_REF"
rm -rf "$WORK/src"; git clone --depth 1 -b "$GIT_REF" "$GIT_URL" "$WORK/src"
echo "    commit: $(git -C "$WORK/src" rev-parse HEAD)"

# The registry must be configured so fpm can resolve the app's required_apps
# (hooks.py). A missing required app (e.g. helpdesk->telephony) fails HERE,
# loudly, instead of at a user's install — which is the correct place for it.
fpm repo add "$PUBLISH_REPO" "$REGISTRY_URL" 2>/dev/null || true

echo "==> [2/4] Package (assets via --bench-path, wheels via --platform/--python-version)"
# --bench-path runs 'bench build --app <app> --production' -> ships public/dist.
# --platform/--python-version target the runtime bench so the vendored wheels are
# the FULL transitive closure for that platform (offline-installable).
fpm package "$WORK/src" \
  --org "$ORG" --app-name "$APP_NAME" --version "$VERSION" \
  --bench-path "$BENCH" \
  --platform "$PLATFORM" --python-version "$PY_VERSION" \
  --repo "$PUBLISH_REPO" \
  -o "$WORK/out" --overwrite --build-verbose
FPM_FILE="$(ls -1 "$WORK/out/${APP_NAME}"-*.fpm | head -1)"
echo "    built: $FPM_FILE"

echo "==> [3/4] Package sanity: assets + wheels present"
python3 - "$FPM_FILE" <<'PY'
import sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
names = z.namelist()
has_dist   = any("/public/dist/" in n for n in names)
has_wheels = any(n.startswith("wheels/") and n.endswith(".whl") for n in names)
print(f"    public/dist present : {has_dist}")
print(f"    vendored wheels     : {sum(n.endswith('.whl') for n in names)}")
# Gap #1 guard: a front-end app with no compiled assets is a bad package.
# (We warn rather than hard-fail here since some apps genuinely have no frontend;
#  step 4 is the real gate.)
if not has_dist:
    print("    WARN: no public/dist in package (front-end app would not render)")
PY

echo "==> [4/4] Validate: offline install into a throwaway sqlite site + boot check"
# This is the gate. It reproduces exactly the failure mode we hit on the registry
# packages: the offline (--no-index) pip install from vendored wheels must
# succeed, and the site must boot with the app installed (no import-error 500).
SITE="validate-${APP_NAME}.local"
bench new-site "$SITE" --db-type sqlite --admin-password admin --force >/dev/null 2>&1 || \
  bench new-site "$SITE" --admin-password admin --force  # fallback if sqlite unsupported
fpm install "$FPM_FILE" --bench-path "$BENCH" --site "$SITE"
echo "    boot check:"
bench --site "$SITE" execute frappe.get_installed_apps
bench drop-site "$SITE" --force --no-backup >/dev/null 2>&1 || true
echo "==> VALIDATION PASSED for $ORG/$APP_NAME==$VERSION"

if [ "$PUBLISH" = "true" ]; then
  echo "==> [publish] $ORG/$APP_NAME==$VERSION -> $PUBLISH_REPO"
  fpm publish "$ORG/$APP_NAME==$VERSION" --repo "$PUBLISH_REPO"
else
  echo "==> [publish] skipped (PUBLISH=false). Artifact at $FPM_FILE"
fi
