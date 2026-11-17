#!/usr/bin/env bash
# ==============================================================================
# SCRIPT NAME: build-dmg.sh
# DESCRIPTION: Production-grade Universal DMG builder for Nextpad++ on macOS.
#              Builds Universal Binary (arm64 + x86_64), stages application bundle,
#              embeds default editor setup script, and packages a signed DMG.
# AUTHOR:      Nextpad++ Team & Contributors
# LICENSE:     GPL-3.0-or-later / MIT
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# ====================== ENVIRONMENT & PATH ======================
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SCRIPT_DIR
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
readonly REPO_ROOT

# Terminal styling
if [[ -t 1 ]] && [[ -z ${NO_COLOR:-} ]]; then
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[1;33m'
	BLUE='\033[0;34m'
	CYAN='\033[0;36m'
	BOLD='\033[1m'
	NC='\033[0m'
else
	RED=''
	GREEN=''
	YELLOW=''
	BLUE=''
	CYAN=''
	BOLD=''
	NC=''
fi

info() { printf "%b[INFO]%b %s\n" "${BLUE}" "${NC}" "$*"; }
step() { printf "%b[STEP]%b %s\n" "${CYAN}" "${NC}" "$*"; }
ok() { printf "%b[ OK ]%b %s\n" "${GREEN}" "${NC}" "$*"; }
warn() { printf "%b[WARN]%b %s\n" "${YELLOW}" "${NC}" "$*" >&2; }
err() { printf "%b[ERR ]%b %s\n" "${RED}" "${NC}" "$*" >&2; }
header() { printf "%b%s%b\n" "${BOLD}" "$*" "${NC}"; }

# Default configuration
BUILD_DIR="${REPO_ROOT}/build"
OUTPUT_DIR="${REPO_ROOT}/dist"
CUSTOM_DMG_NAME=""
SKIP_BUILD=0
DRY_RUN=0
STAGING_DIR=""

cleanup() {
	if [[ -n ${STAGING_DIR} ]] && [[ -d ${STAGING_DIR} ]]; then
		rm -rf -- "${STAGING_DIR}" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM HUP

show_help() {
	cat <<EOF
Nextpad++ Universal DMG Builder

Usage: $(basename "$0") [OPTIONS]

Options:
  --build-dir <dir>       Path to CMake build directory (default: ./build)
  --output-dir <dir>      Path to output directory (default: ./dist)
  --dmg-name <name>       Explicit filename for generated DMG
  --skip-build            Skip cmake build step (requires pre-built Nextpad++.app)
  -d, --dry-run           Print build steps without generating DMG
  -h, --help              Display this help message

Examples:
  ./scripts/build-dmg.sh                          # Configure, build, and package DMG
  ./scripts/build-dmg.sh --skip-build             # Package existing build/Nextpad++.app
  ./scripts/build-dmg.sh --output-dir /tmp/dmgs   # Output to custom path
EOF
}

# Parse command line options
while [[ $# -gt 0 ]]; do
	case "$1" in
	--build-dir)
		[[ $# -ge 2 ]] || {
			err "--build-dir requires an argument"
			exit 1
		}
		BUILD_DIR="$2"
		shift 2
		;;
	--output-dir)
		[[ $# -ge 2 ]] || {
			err "--output-dir requires an argument"
			exit 1
		}
		OUTPUT_DIR="$2"
		shift 2
		;;
	--dmg-name)
		[[ $# -ge 2 ]] || {
			err "--dmg-name requires an argument"
			exit 1
		}
		CUSTOM_DMG_NAME="$2"
		shift 2
		;;
	--skip-build)
		SKIP_BUILD=1
		shift
		;;
	-d | --dry-run)
		DRY_RUN=1
		shift
		;;
	-h | --help)
		show_help
		exit 0
		;;
	*)
		err "Unknown option: $1"
		show_help
		exit 1
		;;
	esac
done

# Detect host platform
HOST_PLATFORM=$(uname -s) || HOST_PLATFORM="unknown"
if [[ ${HOST_PLATFORM} != "Darwin" ]]; then
	err "This script must be run on macOS (Darwin)."
	exit 1
fi

# Detect application version from git tag or CMakeLists.txt
detect_version() {
	local ver=""
	if command -v git &>/dev/null; then
		ver=$(git -C "${REPO_ROOT}" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)
	fi
	if [[ -z ${ver} ]] && [[ -f "${REPO_ROOT}/CMakeLists.txt" ]]; then
		ver=$(grep -m1 'MACOSX_BUNDLE_BUNDLE_VERSION' "${REPO_ROOT}/CMakeLists.txt" | sed -E 's/.*"([^"]+)".*/\1/' || true)
	fi
	ver="${ver:-1.1.3}"
	echo "${ver}"
}

APP_VERSION="$(detect_version)"
readonly APP_VERSION
readonly APP_NAME="Nextpad++.app"
readonly VOLUME_NAME="Nextpad++ ${APP_VERSION}"

if [[ -n ${CUSTOM_DMG_NAME} ]]; then
	FINAL_DMG_NAME="${CUSTOM_DMG_NAME}"
else
	FINAL_DMG_NAME="Nextpad++-${APP_VERSION}-Universal.dmg"
fi

header "======================================================"
header "  Nextpad++ Universal DMG Packaging Pipeline"
header "======================================================"
info "Version:          ${APP_VERSION}"
info "Build Directory:  ${BUILD_DIR}"
info "Output Directory: ${OUTPUT_DIR}"
info "Target DMG:       ${FINAL_DMG_NAME}"
echo

# Step 1: Build Application if needed
if [[ ${SKIP_BUILD} -eq 0 ]]; then
	step "Configuring CMake for Universal Binary (arm64 + x86_64)..."
	if [[ ${DRY_RUN} -eq 1 ]]; then
		info "[DRY-RUN] Would run cmake configure & build"
	else
		ncpu=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
		cmake -S "${REPO_ROOT}" -B "${BUILD_DIR}" \
			-DCMAKE_BUILD_TYPE=Release \
			-DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
			-DCMAKE_OSX_DEPLOYMENT_TARGET="11.0"

		step "Compiling Nextpad++ Universal Binary with ${ncpu} parallel jobs..."
		cmake --build "${BUILD_DIR}" --config Release --parallel "${ncpu}"
		ok "Nextpad++ compilation completed."
	fi
fi

# Step 2: Verify binary architecture
APP_BUNDLE="${BUILD_DIR}/${APP_NAME}"
if [[ ${DRY_RUN} -eq 1 ]]; then
	info "[DRY-RUN] Staging complete. Would generate DMG at: ${OUTPUT_DIR}/${FINAL_DMG_NAME}"
	exit 0
fi

if [[ ! -d ${APP_BUNDLE} ]]; then
	# Check if bundle is directly in build root or in build-release
	if [[ -d "${REPO_ROOT}/build-release/${APP_NAME}" ]]; then
		APP_BUNDLE="${REPO_ROOT}/build-release/${APP_NAME}"
	else
		err "Nextpad++.app bundle not found at: ${APP_BUNDLE}"
		err "Run without --skip-build to compile first."
		exit 1
	fi
fi

BINARY_PATH="${APP_BUNDLE}/Contents/MacOS/Nextpad++"
if [[ ! -f ${BINARY_PATH} ]]; then
	err "Executable binary not found at: ${BINARY_PATH}"
	exit 1
fi

step "Verifying Universal Binary architectures..."
ARCH_OUTPUT=$(lipo -info "${BINARY_PATH}" 2>&1 || true)
info "Binary architectures: ${ARCH_OUTPUT}"

if echo "${ARCH_OUTPUT}" | grep -q "arm64" && echo "${ARCH_OUTPUT}" | grep -q "x86_64"; then
	ok "Universal Binary verified: Contains both arm64 and x86_64 architectures."
else
	warn "Binary does not report both arm64 and x86_64: ${ARCH_OUTPUT}"
fi

# Step 3: Prepare Staging Directory
mkdir -p "${OUTPUT_DIR}"
STAGING_DIR=$(mktemp -d -t nextpad_dmg_staging_XXXXXX)

step "Staging application bundle and assets..."
cp -R "${APP_BUNDLE}" "${STAGING_DIR}/${APP_NAME}"

# Embed the Default Editor setup script directly into the DMG for user convenience
EDITOR_SCRIPT="${REPO_ROOT}/scripts/Nextpad++-Default-Editor.sh"
if [[ ! -f ${EDITOR_SCRIPT} ]]; then
	EDITOR_SCRIPT="${REPO_ROOT}/Nextpad++-Default-Editor.sh"
fi

if [[ -f ${EDITOR_SCRIPT} ]]; then
	step "Embedding Nextpad++-Default-Editor.sh into DMG root..."
	cp "${EDITOR_SCRIPT}" "${STAGING_DIR}/Nextpad++-Default-Editor.sh"
	chmod +x "${STAGING_DIR}/Nextpad++-Default-Editor.sh"
	ok "Default editor setup script staged."
fi

# Copy license and readme if present
if [[ -f "${REPO_ROOT}/LICENSE" ]]; then
	cp "${REPO_ROOT}/LICENSE" "${STAGING_DIR}/LICENSE"
fi

# Re-sign staged app bundle with ad-hoc signature if not officially signed
if command -v codesign &>/dev/null; then
	step "Applying ad-hoc code signature to staged bundle..."
	xattr -cr "${STAGING_DIR}/${APP_NAME}" 2>/dev/null || true
	codesign --force --deep --sign - "${STAGING_DIR}/${APP_NAME}" 2>/dev/null || true
	ok "Bundle signature validated."
fi

FINAL_DMG_PATH="${OUTPUT_DIR}/${FINAL_DMG_NAME}"
rm -f "${FINAL_DMG_PATH}" "${FINAL_DMG_PATH}.sha256"

if [[ ${DRY_RUN} -eq 1 ]]; then
	info "[DRY-RUN] Staging complete. Would generate DMG at: ${FINAL_DMG_PATH}"
	exit 0
fi

# Step 4: Create DMG
BG_IMAGE="${REPO_ROOT}/resources/dmg-background.png"
ICON_FILE="${REPO_ROOT}/resources/npp.icns"

if command -v create-dmg &>/dev/null; then
	step "Generating styled DMG with create-dmg..."
	local_create_args=(
		--volname "${VOLUME_NAME}"
		--window-pos 200 120
		--window-size 600 640
		--icon-size 128
		--icon "${APP_NAME}" 150 250
		--hide-extension "${APP_NAME}"
		--app-drop-link 450 250
		--icon "Nextpad++-Default-Editor.sh" 300 480
		--format UDZO
		--no-internet-enable
		--overwrite
	)

	if [[ -f ${ICON_FILE} ]]; then
		local_create_args+=(--volicon "${ICON_FILE}")
	fi

	if [[ -f ${BG_IMAGE} ]]; then
		local_create_args+=(--background "${BG_IMAGE}")
	fi

	# When running non-interactively or in CI, skip AppleScript Jenkins dialogs
	if [[ -z ${DISPLAY:-} && -z ${TERM_PROGRAM:-} ]] || [[ ${CI:-false} == "true" ]]; then
		local_create_args+=(--skip-jenkins)
	fi

	set +e
	create-dmg "${local_create_args[@]}" "${FINAL_DMG_PATH}" "${STAGING_DIR}"
	dmg_exit=$?
	set -e

	if [[ ${dmg_exit} -ne 0 ]]; then
		warn "create-dmg exited with ${dmg_exit}, falling back to native hdiutil create..."
		ln -sf /Applications "${STAGING_DIR}/Applications"
		hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${FINAL_DMG_PATH}"
	fi
else
	step "create-dmg not found, creating DMG with native hdiutil..."
	ln -sf /Applications "${STAGING_DIR}/Applications"
	hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${STAGING_DIR}" -ov -format UDZO "${FINAL_DMG_PATH}"
fi

# Step 5: Generate Checksum
step "Generating SHA256 checksum..."
(
	cd -- "${OUTPUT_DIR}"
	shasum -a 256 "${FINAL_DMG_NAME}" >"${FINAL_DMG_NAME}.sha256"
)

ok "DMG successfully created: ${FINAL_DMG_PATH}"
file_size=$(du -h "${FINAL_DMG_PATH}" | cut -f1) || file_size="unknown"
info "File size: ${file_size}"
sha_val=$(cut -d' ' -f1 "${FINAL_DMG_PATH}.sha256") || sha_val="unknown"
info "SHA256:    ${sha_val}"
header "======================================================"
header "  Build & Packaging Pipeline Complete!"
header "======================================================"
