#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PI_GEN_DIR="${SCRIPT_DIR}/pi-gen"
PI_GEN_REPO="https://github.com/RPi-Distro/pi-gen.git"
PI_GEN_BRANCH="arm"

# ── Check prerequisites ────────────────────────────────────────────────────────
check_deps() {
    local missing=()
    for cmd in git docker; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo "ERROR: Missing required tools: ${missing[*]}" >&2
        exit 1
    fi
}

# ── Clone / update pi-gen ──────────────────────────────────────────────────────
prepare_pigen() {
    if [ ! -d "${PI_GEN_DIR}/.git" ]; then
        echo ">>> Cloning pi-gen (branch: ${PI_GEN_BRANCH}) ..."
        git clone --depth 1 --branch "${PI_GEN_BRANCH}" \
            "${PI_GEN_REPO}" "${PI_GEN_DIR}"
    else
        echo ">>> Updating pi-gen ..."
        git -C "${PI_GEN_DIR}" pull --ff-only
    fi
}

# ── Symlink custom stage into pi-gen work tree ─────────────────────────────────
link_custom_stage() {
    local target="${PI_GEN_DIR}/stage-devterm"
    if [ -L "${target}" ]; then
        rm "${target}"
    fi
    ln -s "${SCRIPT_DIR}/stage-devterm" "${target}"
    echo ">>> Linked stage-devterm -> ${target}"
}

# ── Copy config and run Docker build ──────────────────────────────────────────
run_build() {
    cp -f "${SCRIPT_DIR}/config" "${PI_GEN_DIR}/config"

    echo ">>> Starting Docker build ..."
    cd "${PI_GEN_DIR}"
    bash build-docker.sh
}

# ── Copy artifacts back to project root ───────────────────────────────────────
collect_artifacts() {
    local deploy_dir="${PI_GEN_DIR}/deploy"
    if [ -d "${deploy_dir}" ]; then
        echo ">>> Copying build artifacts to ${SCRIPT_DIR}/deploy/ ..."
        mkdir -p "${SCRIPT_DIR}/deploy"
        cp -v "${deploy_dir}"/*.img.xz "${SCRIPT_DIR}/deploy/" 2>/dev/null || true
        cp -v "${deploy_dir}"/*.sha256 "${SCRIPT_DIR}/deploy/" 2>/dev/null || true
        echo ">>> Build complete. Images:"
        ls -lh "${SCRIPT_DIR}/deploy/"
    else
        echo "WARNING: Deploy directory not found at ${deploy_dir}" >&2
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────────
check_deps
prepare_pigen
link_custom_stage
run_build
collect_artifacts
