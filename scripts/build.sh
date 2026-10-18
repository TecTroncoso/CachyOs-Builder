#!/usr/bin/env bash
#
# CachyOSMod - build.sh
# Orquestador local/CI:
#   1. Clona (o reutiliza) la base 100% CachyOS (CachyOS-Live-ISO) fijada a
#      un commit concreto (BASE_REF) para builds reproducibles.
#   2. Aplica nuestro overlay/ (fragments de paquetes, profiledef, branding).
#   3. Instala nuestro util-iso.sh multi-perfil encima del original.
#   4. Ejecuta buildiso.sh -p <perfil>.
#
# Uso:
#   ./build.sh [perfil]            # ej: ./build.sh kde-default-complete
#   Perfil por defecto: kde-default-complete
#
# Variables opcionales:
#   BASE_REPO  (default: https://github.com/CachyOS/CachyOS-Live-ISO.git)
#   BASE_REF   (default: commit fijado abajo)
#
set -euo pipefail

BASE_REPO="${BASE_REPO:-https://github.com/CachyOS/CachyOS-Live-ISO.git}"
BASE_REF="${BASE_REF:-3215497d2e8c5fea90e185affcf973dfa2cf790b}"
PROFILE="${1:-kde-default-complete}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
WORK="${PROJECT_DIR}/.work"
BASE="${WORK}/base"

echo "==> CachyOSMod build"
echo "    Base repo : ${BASE_REPO}"
echo "    Base ref  : ${BASE_REF}"
echo "    Perfil    : ${PROFILE}"

# Validar formato de perfil (escritorio-kernel-apps)
if [[ ! "${PROFILE}" =~ ^(kde|gnome|xfce)-(default|bore|lts)-(complete|minimal)$ ]]; then
    echo "ERROR: perfil invalido '${PROFILE}'. Formato: <kde|gnome|xfce>-<default|bore|lts>-<complete|minimal>" >&2
    exit 1
fi

# 1) Clonar / actualizar la base CachyOS
if [[ ! -d "${BASE}/.git" ]]; then
    echo "==> Cloning CachyOS-Live-ISO (base) ..."
    mkdir -p "${WORK}"
    git clone "${BASE_REPO}" "${BASE}"
fi
echo "==> Checking out BASE_REF ..."
git -C "${BASE}" fetch --all --tags --quiet
git -C "${BASE}" checkout -f "${BASE_REF}"

# 2) Aplicar nuestro overlay (archiso/... -> base/archiso/...)
echo "==> Applying overlay ..."
if command -v rsync >/dev/null 2>&1; then
    rsync -a "${PROJECT_DIR}/overlay/" "${BASE}/"
else
    cp -r "${PROJECT_DIR}/overlay/." "${BASE}/"
fi

# 3) Instalar nuestro util-iso.sh multi-perfil
echo "==> Installing multi-profile util-iso.sh ..."
cp "${SCRIPT_DIR}/util-iso.sh" "${BASE}/util-iso.sh"
chmod +x "${BASE}/buildiso.sh" "${BASE}/util-iso.sh"

# 4) Construir la ISO
echo "==> Building ISO [${PROFILE}] ..."
cd "${BASE}"
BUILD_ARGS=(-p "${PROFILE}")
./buildiso.sh "${BUILD_ARGS[@]}" -w

echo "==> Done. ISOs en: ${BASE}/out/${PROFILE}/"
ls -lh "${BASE}/out/${PROFILE}/" 2>/dev/null || true
