#!/bin/bash
#
# CachyOSMod - util-iso.sh (version MULTI-PERFIL)
# Basado en util-iso.sh de CachyOS-Live-ISO (commit 3215497d).
# Cambios principales respecto al original:
#   * prepare_profile() ahora acepta perfiles compuestos
#     <escritorio>-<kernel>-<apps>  (ej. kde-bore-complete)
#   * Compone archiso/packages.x86_64 a partir de fragments.
#   * Selecciona el display-manager segun el escritorio.
#   * Rebranding CachyOSMod (iso_name, motd, tags).
#
set -e

# Nombre del ISO generado por mkarchiso (debe coincidir con iso_name en
# overlay/archiso/profiledef.sh). Se usa para renombrar la salida.
iso_name="cachyosmod"

error_function() {
    if [[ -p $logpipe ]]; then
        rm "$logpipe"
    fi
    if (( ! BASH_SUBSHELL )); then
        error "A failure occurred in %s()." "$1"
        plain "Aborting..."
    fi
    umount_fs
    umount_img
    exit 2
}

run_safe() {
    local restoretrap func="$1"
    set -e
    set -E
    restoretrap=$(trap -p ERR)
    trap 'error_function $func' ERR
    if ${verbose}; then
        run_log "$func"
    else
        "$func"
    fi
    eval $restoretrap
    set +E
    set +e
}

check_umount() {
    if mountpoint -q "$1"; then
        umount -l "$1"
    fi
}

trap_exit() {
    local sig=$1; shift
    error "$@"
    umount_fs
    trap -- "$sig"
    kill "-$sig" "$$"
}

generate_motd() {
    local _profile="$1"
    cat << EOF > ${src_dir}/archiso/airootfs/etc/motd
This ISO is based on CachyOS modified as CachyOSMod.
Base upstream: https://github.com/CachyOS/CachyOS-Live-ISO
CachyOS:       https://cachyos.org

Profile: ${_profile}

Calamares is used as GUI installer.
Welcome to your CachyOSMod!
EOF
}

fetch_cachyos_mirrorlist() {
    mkdir -p ${src_dir}/archiso/airootfs/etc/pacman.d
    local _mirrorlist_url="https://github.com/CachyOS/CachyOS-PKGBUILDS/raw/master/cachyos-mirrorlist/cachyos-mirrorlist"
    curl -sSL "${_mirrorlist_url}" > ${src_dir}/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist
}

change_grub_version() {
    local _version="$1"
    sed -i "s/CACHYOS_VERSION=\".*\"/CACHYOS_VERSION=\"${_version}\"/" ${src_dir}/archiso/grub/grub.cfg
}

generate_environment() {
    local _profile="$1"
    cat << 'EOF' > ${src_dir}/archiso/airootfs/etc/environment
ZPOOL_VDEV_NAME_PATH=1
EOF
}

generate_version_tag() {
    local _profile="$1"
    local _version="$2"
    echo "${_version}" > ${src_dir}/archiso/airootfs/etc/version-tag
}

generate_edition_tag() {
    local _edition="$1"
    echo "${_edition}" > ${src_dir}/archiso/airootfs/etc/edition-tag
}

# Compone packages.x86_64 a partir de los fragments del perfil.
compose_packages() {
    local _desktop="$1" _kernel="$2" _apps="$3"
    local _fragments=(
        "${src_dir}/archiso/packages_base.x86_64"
        "${src_dir}/archiso/packages_desktop-${_desktop}.x86_64"
        "${src_dir}/archiso/packages_kernel-${_kernel}.x86_64"
        "${src_dir}/archiso/packages_apps-${_apps}.x86_64"
    )
    local _out="${src_dir}/archiso/packages.x86_64"
    local _f

    : > "${_out}"
    for _f in "${_fragments[@]}"; do
        if [[ ! -f "${_f}" ]]; then
            die "Missing package fragment: [%s]" "${_f}"
        fi
        cat "${_f}" >> "${_out}"
    done

    grep -vE '^[[:space:]]*(#|$)' "${_out}" | sort -u > "${_out}.tmp"
    mv "${_out}.tmp" "${_out}"

    msg2 "Composed %s packages (desktop=%s kernel=%s apps=%s)" \
        "$(wc -l < "${_out}")" "${_desktop}" "${_kernel}" "${_apps}"
}

# Enlaza el display-manager segun el escritorio.
set_display_manager() {
    local _desktop="$1"
    local _dm_link="${src_dir}/archiso/airootfs/etc/systemd/system/display-manager.service"
    local _dm=""

    case "${_desktop}" in
        kde)   _dm="/usr/lib/systemd/system/plasmalogin.service" ;;
        gnome) _dm="/usr/lib/systemd/system/gdm.service" ;;
        xfce)  _dm="/usr/lib/systemd/system/lightdm.service" ;;
        *)     die "Unknown desktop for display-manager: [%s]" "${_desktop}" ;;
    esac

    rm -f "${_dm_link}"
    ln -sf "${_dm}" "${_dm_link}"
    msg2 "Display-manager -> %s" "${_dm}"
}

# Habilita los repos optimizados de CachyOS (x86-64-v3 / v4).
# ARCH_TUNE=generic -> no toca nada (build y live quedan como la base);
# v3 / v4 / v3v4 -> trata cada pacman.conf de forma DISTINTA, igual que
# hace el CachyOS oficial:
#
#   1) archiso/pacman.conf -> conf de BUILD (lo usa pacstrap/mkarchiso en
#      el runner para hornear los paquetes del airootfs). Aqui SI se fuerza
#      'Architecture = x86_64_vN ... x86_64' y Server lines LITERALES:
#        * un pacman con 'auto' rechazaria los paquetes optimizados en
#          runners sin AVX2/AVX-512 ("package architecture is not valid");
#        * los mirrorlists cachyos-v{3,4} usan la variable $arch_v{3,4}
#          (parche propio del pacman de CachyOS) cuya expansion se corrompe
#          con una lista multiple en Architecture (404 en todos los mirrors).
#      Mirrors verificados: cdn77/us/at sirven /repo/x86_64_vN/; el repo
#      generico vive bajo /repo/x86_64/, asi que tambien se fijan las URLs
#      del [cachyos] de build (la base apunta a mirror.cachyos.org,
#      marcado inestable upstream).
#
#   2) archiso/airootfs/etc/pacman.conf -> /etc/pacman.conf del sistema
#      LIVE (y del INSTALADO: el sistema instalado lo hereda). Aqui se
#      replica el mecanismo OFICIAL de CachyOS para que la seleccion del
#      nivel ocurra EN RUNTIME segun la CPU de cada maquina:
#      ver apply_live_arch_tune().
# Tratamiento del pacman.conf del sistema live/instalado: replica el
# mecanismo OFICIAL de CachyOS (wiki "Optimized Repositories") para que la
# seleccion v3/v4/generico ocurra EN RUNTIME segun la CPU de cada maquina,
# sin volver a hornear la ISO:
#
#   * 'Architecture = auto': el pacman parcheado de CachyOS (viaja en la
#     ISO como cachyos/pacman) detecta la CPU en cada arranque y expande
#     'auto' a la lista [x86_64, x86_64_v2?, x86_64_v3?, x86_64_v4?].
#     Los paquetes de niveles que la CPU no soporta se descartan solos y
#     pacman cae al siguiente repo de la cascada -> v4 -> v3 -> generico.
#   * Secciones v3/v4 con 'Include = /etc/pacman.d/cachyos-vN-mirrorlist':
#     esos archivos los instalan los paquetes cachyos-v{3,4}-mirrorlist (ya
#     incluidos en el listado de la ISO) y sus Server lines usan
#     $arch_v{3,4}, variables que solo expande el pacman parcheado. Es
#     exactamente la configuracion que lleva un CachyOS oficial instalado.
#   * 'SigLevel = Optional TrustAll': mismo criterio que el conf live
#     oficial aplica a [cachyos]; el keyring del live solo se pobla con la
#     clave de Arch (pacstrap -K), no con la de CachyOS.
apply_live_arch_tune() {
    local _conf="$1"; shift
    local _levels=("$@")
    local _lv _block

    # Idempotencia: eliminar el bloque inyectado previamente.
    sed -i '/^# >>> CachyOSMod arch-tune (runtime) >>>$/,/^# <<< CachyOSMod arch-tune (runtime) <<<$/{d}' "${_conf}"

    # Architecture = auto: deteccion de CPU en runtime (pacman parcheado).
    if grep -qE '^[[:space:]]*Architecture[[:space:]]*=' "${_conf}"; then
        sed -i -E "s|^[[:space:]]*Architecture[[:space:]]*=.*|Architecture = auto|" "${_conf}"
    elif grep -qE '^[[:space:]]*#[[:space:]]*Architecture[[:space:]]*=' "${_conf}"; then
        sed -i -E "s|^[[:space:]]*#[[:space:]]*Architecture[[:space:]]*=.*|Architecture = auto|" "${_conf}"
    else
        sed -i "/^\[options\]/a Architecture = auto" "${_conf}"
    fi

    # Secciones v3/v4 con los mirrorlists del propio sistema (estilo oficial).
    _block="${_conf}.tune"
    {
        printf '# >>> CachyOSMod arch-tune (runtime) >>>\n'
        printf '\n'
        for _lv in "${_levels[@]}"; do
            printf '[cachyos-%s]\n' "${_lv}"
            printf 'SigLevel = Optional TrustAll\n'
            printf 'Include = /etc/pacman.d/cachyos-%s-mirrorlist\n' "${_lv}"
            printf '\n'
            printf '[cachyos-core-%s]\n' "${_lv}"
            printf 'SigLevel = Optional TrustAll\n'
            printf 'Include = /etc/pacman.d/cachyos-%s-mirrorlist\n' "${_lv}"
            printf '\n'
            printf '[cachyos-extra-%s]\n' "${_lv}"
            printf 'SigLevel = Optional TrustAll\n'
            printf 'Include = /etc/pacman.d/cachyos-%s-mirrorlist\n' "${_lv}"
            printf '\n'
        done
        printf '# <<< CachyOSMod arch-tune (runtime) <<<\n'
    } > "${_block}"
    awk 'NR==FNR{b=b $0 ORS; next} /^\[cachyos\]$/ && !done{printf "%s", b; done=1} {print}' \
        "${_block}" "${_conf}" > "${_conf}.tmp"
    mv "${_conf}.tmp" "${_conf}"
    rm -f "${_block}"

    if grep -q "^\[cachyos-${_levels[0]}\]$" "${_conf}"; then
        msg2 "Arch tune [live %s]: estilo oficial (Architecture = auto + Include cachyos-v{3,4}-mirrorlist)" "${_conf}"
    else
        warning "No se pudo inyectar [cachyos-%s] en %s" "${_levels[0]}" "${_conf}"
    fi
}

apply_arch_tune() {
    local _tune="${ARCH_TUNE:-generic}"

    if [[ "${_tune}" == "generic" ]]; then
        msg2 "Arch tune: generic (build y live quedan como la base, sin repos v3/v4)"
        return 0
    fi

    # Niveles a habilitar, en orden de prioridad (el primero queda mas arriba).
    local _levels=()
    case "${_tune}" in
        v3)   _levels=(v3) ;;
        v4)   _levels=(v4) ;;
        v3v4) _levels=(v4 v3) ;;
        *)    die "Unknown arch tune: [%s] (use generic|v3|v4|v3v4)" "${_tune}" ;;
    esac

    # Arquitecturas que aceptara el pacman de BUILD: nivel(es) + generico.
    local _archs=""
    case "${_tune}" in
        v3)   _archs="x86_64_v3 x86_64" ;;
        v4)   _archs="x86_64_v4 x86_64" ;;
        v3v4) _archs="x86_64_v4 x86_64_v3 x86_64" ;;
    esac

    local _conf_build="${src_dir}/archiso/pacman.conf"
    local _conf_live="${src_dir}/archiso/airootfs/etc/pacman.conf"
    local _lv _block

    # --- Conf de BUILD: multi-arch forzado + Server lines literales --------
    if [[ ! -f "${_conf_build}" ]]; then
        warning "Arch tune: no existe [%s], se omite el conf de build" "${_conf_build}"
    else
        # 1) Bloques de repos del nivel, justo antes de la seccion [cachyos].
        #    Servers literales (verificados) en vez del Include de
        #    cachyos-v{3,4}-mirrorlist (que usa $arch_v{3,4}).
        _block="${_conf_build}.tune"
        : > "${_block}"
        for _lv in "${_levels[@]}"; do
            {
                printf '[cachyos-%s]\n' "${_lv}"
                printf 'Server = https://cdn77.cachyos.org/repo/x86_64_%s/$repo\n' "${_lv}"
                printf 'Server = https://us.cachyos.org/repo/x86_64_%s/$repo\n' "${_lv}"
                printf 'Server = https://at.cachyos.org/repo/x86_64_%s/$repo\n' "${_lv}"
                printf '[cachyos-core-%s]\n' "${_lv}"
                printf 'Server = https://cdn77.cachyos.org/repo/x86_64_%s/$repo\n' "${_lv}"
                printf 'Server = https://us.cachyos.org/repo/x86_64_%s/$repo\n' "${_lv}"
                printf 'Server = https://at.cachyos.org/repo/x86_64_%s/$repo\n' "${_lv}"
                printf '[cachyos-extra-%s]\n' "${_lv}"
                printf 'Server = https://cdn77.cachyos.org/repo/x86_64_%s/$repo\n' "${_lv}"
                printf 'Server = https://us.cachyos.org/repo/x86_64_%s/$repo\n' "${_lv}"
                printf 'Server = https://at.cachyos.org/repo/x86_64_%s/$repo\n' "${_lv}"
            } >> "${_block}"
        done
        awk 'NR==FNR{b=b $0 ORS; next} /^\[cachyos\]$/ && !done{printf "%s", b; done=1} {print}' \
            "${_block}" "${_conf_build}" > "${_conf_build}.tmp"
        mv "${_conf_build}.tmp" "${_conf_build}"
        rm -f "${_block}"

        # 2) Architecture: aceptar los paquetes del nivel optimizado + generico.
        if grep -qE '^[[:space:]]*Architecture[[:space:]]*=' "${_conf_build}"; then
            sed -i -E "s|^[[:space:]]*Architecture[[:space:]]*=.*|Architecture = ${_archs}|" "${_conf_build}"
        elif grep -qE '^[[:space:]]*#[[:space:]]*Architecture[[:space:]]*=' "${_conf_build}"; then
            sed -i -E "s|^[[:space:]]*#[[:space:]]*Architecture[[:space:]]*=.*|Architecture = ${_archs}|" "${_conf_build}"
        else
            sed -i "/^\[options\]/a Architecture = ${_archs}" "${_conf_build}"
        fi

        # 3) Repo generico [cachyos]: la base apunta a mirror.cachyos.org
        #    (inestable) con $arch; lo sustituimos por cdn77 (CDN principal)
        #    + fallbacks, todos con ruta literal.
        sed -i 's|^Server = https://mirror\.cachyos\.org/repo/\$arch/\$repo$|Server = https://cdn77.cachyos.org/repo/x86_64/$repo\nServer = https://us.cachyos.org/repo/x86_64/$repo\nServer = https://mirror.cachyos.org/repo/x86_64/$repo|' "${_conf_build}"
        # Por si quedara alguna otra Server line con $arch: fijarla a x86_64
        # (el repo generico vive bajo /repo/x86_64/ en los mirrors).
        sed -i '/^Server = /s|\$arch|x86_64|g' "${_conf_build}"

        # 4) [core]/[extra]/[multilib] resuelven el Include contra el
        #    mirrorlist del CONTENEDOR (que usa $arch); se sustituye por un
        #    server literal determinista.
        sed -i 's|^Include = /etc/pacman\.d/mirrorlist$|Server = https://geo.mirror.pkgbuild.com/$repo/os/x86_64|' "${_conf_build}"

        if grep -q "^\[cachyos-${_levels[0]}\]$" "${_conf_build}"; then
            msg2 "Arch tune [build %s]: repos inyectados, Architecture = %s" "${_conf_build}" "${_archs}"
        else
            warning "No se pudo inyectar [cachyos-%s] en %s" "${_levels[0]}" "${_conf_build}"
        fi
    fi

    # --- Conf LIVE: mecanismo oficial (seleccion en runtime segun la CPU) --
    if [[ -f "${_conf_live}" ]]; then
        apply_live_arch_tune "${_conf_live}" "${_levels[@]}"
    else
        warning "Arch tune: no existe [%s], se omite el conf live" "${_conf_live}"
    fi

    # 5) El mirrorlist de Arch incluido en la ISO (lo usa el live para
    #    [core]/[extra]/[multilib]) tambien usa $arch: fijarlo.
    if [[ -f "${src_dir}/archiso/airootfs/etc/pacman.d/mirrorlist" ]]; then
        sed -i '/^Server = /s|\$arch|x86_64|g' "${src_dir}/archiso/airootfs/etc/pacman.d/mirrorlist"
    fi

    # 6) Y el mirrorlist de CachyOS descargado para el live (repo [cachyos]).
    if [[ -f "${src_dir}/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist" ]]; then
        sed -i '/^Server = /s|\$arch|x86_64|g' "${src_dir}/archiso/airootfs/etc/pacman.d/cachyos-mirrorlist"
    fi

    msg2 "Arch tune: %s -> niveles %s (repos cachyos, cachyos-core y cachyos-extra de cada nivel)" "${_tune}" "${_levels[*]}"
}

# Desactiva el timer archlinux-keyring-wkd-sync dentro del airootfs.
#
# FIX (v3/v4 build 2026-10-18): el parche original de CachyOS inyectaba
# tras "_run_once _make_customize_airootfs" un rm usando la variable
# pacman_dir, que NO existe en mkarchiso (la real es pacstrap_dir).
# mkarchiso corre con "set -e -u", asi que el build moria con
# "pacman_dir: unbound variable" justo despues de instalar los paquetes.
# Con archiso 91 (el que instala CI) mkarchiso ya no referencia ese
# timer y el archlinux-keyring moderno tampoco activa el timer dentro
# del airootfs, asi que el parche es innecesario: esta funcion pasa a
# ser informativa (no-op) y nunca rompe el build.
modify_mkarchiso() {
    if grep -q 'archlinux-keyring-wkd-sync.timer' /usr/bin/mkarchiso; then
        msg "mkarchiso ya gestiona el timer archlinux-keyring-wkd-sync; no se parchea"
    else
        msg "mkarchiso 91+: el timer del keyring ya no aplica; no se parchea"
    fi
}

prepare_profile(){
    profile=$1

    info "Profile: [%s]" "${profile}"

    # Formato <escritorio>-<kernel>-<apps>
    local _desktop _kernel _apps
    IFS='-' read -r _desktop _kernel _apps <<< "${profile}"

    case "${_desktop}" in kde|gnome|xfce) ;; *) die "Unknown desktop: [%s] (use kde|gnome|xfce)" "${_desktop}";; esac
    case "${_kernel}"  in default|bore|lts)       ;; *) die "Unknown kernel: [%s] (use default|bore|lts)" "${_kernel}";; esac
    case "${_apps}"    in complete|minimal) ;; *) die "Unknown apps: [%s] (use complete|minimal)" "${_apps}";; esac

    local _iso_version="$(date +%y%m%d)"
    change_grub_version "${_iso_version}"

    # Mirrorlist actualizado de CachyOS
    fetch_cachyos_mirrorlist

    # Enmascarar el timer de rate-mirrors
    ln -sf /dev/null ${src_dir}/archiso/airootfs/etc/systemd/system/cachyos-rate-mirrors.timer

    generate_motd "${profile}"

    # Compone el listado de paquetes del perfil
    compose_packages "${_desktop}" "${_kernel}" "${_apps}"

    # Display-manager del escritorio elegido
    set_display_manager "${_desktop}"

    # Habilitar repos optimizados v3/v4/v3v4 si se pidio
    apply_arch_tune

    generate_environment "${profile}"
    generate_version_tag "${profile}" "${_iso_version}"
    generate_edition_tag "${profile}"

    iso_file=$(gen_iso_fn).iso
}

run_build() {
    prepare_profile "$1"
    local _profile="$1"

    msg "Prepare [work: ${work_dir}, out: ${outFolder}]"

    if $verbose; then
        msg2 "Making mkarchiso verbose"
        sudo sed -i 's/quiet="y"/quiet="n"/g' /usr/bin/mkarchiso
    fi

    if $clean_first; then
        msg2 "Deleting the build folder if one exists - takes some time"
        umount_fs
        [ -d ${work_dir} ] && sudo rm -rf ${work_dir}
    fi

    msg2 "Copying the Archiso folder to build work"
    mkdir -p ${work_dir}
    cp -r archiso ${work_dir}/archiso

    msg "Start [Build ISO]"

    modify_mkarchiso

    [ -d "$outFolder/$_profile" ] || mkdir -p "$outFolder/$_profile"
    cd ${work_dir}/archiso/
    sudo mkarchiso -v -w ${work_dir} -o "$outFolder/$_profile" ${work_dir}/archiso/
    sudo chown $USER $outFolder

    cp ${work_dir}/iso/arch/pkglist.x86_64.txt "$outFolder/$_profile/$(gen_iso_fn).pkgs.txt"

    # mkarchiso genera <iso_name>-<YYYY.MM.DD>-x86_64.iso
    local _built_iso="$outFolder/$_profile/${iso_name}-$(date --date="@${SOURCE_DATE_EPOCH:-$(date +%s)}" +%Y.%m.%d)-x86_64.iso"
    if [[ -f "${_built_iso}" ]]; then
        mv "${_built_iso}" "$outFolder/$_profile/${iso_file}"
    else
        warning "Expected ISO [%s] not found; skipping rename." "${_built_iso}"
    fi

    msg "Done [Build ISO] ${iso_file}"
    msg "Finished building [%s]" "${_profile}"

    cd "$outFolder/$_profile"
    for f in $(find . -maxdepth 1 -name '*.iso' | cut -d'/' -f2); do
        if [[ ! -e $f.sha256 ]]; then
            create_chksums $f
        elif [[ $f -nt $f.sha256 ]]; then
            create_chksums $f
        else
            info "checksums for [$f] already created"
        fi
    done
    show_elapsed_time "${FUNCNAME}" "${timer_start}"
    if [[ "$remove_build_dir" == "true" ]]; then
        msg "Automatically removing build directory ($work_dir)..."
        umount_fs
        [ -d ${work_dir} ] && sudo rm -rf ${work_dir}
        msg2 "Removed"
    fi
}

gen_iso_fn(){
    local vars=() name
    vars+=("cachyosmod")
    [[ -n ${profile} ]] && vars+=("${profile}")
    [[ "${ARCH_TUNE:-generic}" != "generic" ]] && vars+=("${ARCH_TUNE}")
    vars+=("$(date +%y%m%d)")

    for n in ${vars[@]}; do
        name=${name:-}${name:+-}${n}
    done

    echo $name
}

