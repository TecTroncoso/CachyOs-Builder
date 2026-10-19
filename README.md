# CachyOSMod

ISOs personalizadas construidas sobre la **base 100% CachyOS**
([CachyOS/CachyOS-Live-ISO](https://github.com/CachyOS/CachyOS-Live-ISO)),
con un sistema de **perfiles compuestos** (escritorio × kernel × aplicaciones),
**optimización CPU opcional** (repos oficiales v3/v4/v3v4)
y construcción automática en **GitHub Actions**.

> Este repo **no** duplica los binarios de CachyOS. Clona la base oficial fijada
> a un commit concreto en cada build, le encima tus modificaciones (overlay) y
> construye la ISO. Así la base se mantiene intacta y tus cambios están separados.

---

## Cómo funciona (investigación)

CachyOS construye su ISO con el sistema oficial **archiso** de Arch Linux:

1. `buildiso.sh -p <perfil>` llama a `run_build` en `util-iso.sh`.
2. `prepare_profile()` copia `packages_<perfil>.x86_64` → `packages.x86_64`,
   enlaza el *display-manager*, genera motd y tags de versión.
3. `mkarchiso -v -w build -o out/<perfil>/ archiso/` empaqueta todo en una ISO
   (squashfs + GRUB/syslinux) y la deja en `out/`.

La base es un **perfil archiso** estándar: `archiso/profiledef.sh`,
`pacman.conf`, listados `packages*.x86_64`, overlay `airootfs/` y configs de
`grub/`, `efiboot/`, `syslinux/`.

**CachyOSMod** reutiliza todo eso y añade:
- Perfiles **compuestos** `<escritorio>-<kernel>-<apps>` (la etiqueta se parte
  en 3 y cada trozo selecciona un *fragment* de paquetes; no existe un archivo
  por perfil, sino que se concatenan: base + escritorio + kernel + apps).
- Selección de display-manager según el escritorio (KDE→plasmalogin,
  GNOME→gdm, Xfce→lightdm).
- Optimización CPU opcional (`ARCH_TUNE`): hornea los paquetes del nivel
  elegido (repos oficiales v3/v4/v3v4 en el conf de build) y configura el
  `pacman.conf` del sistema live/instalado con el **mecanismo oficial de
  CachyOS** (`Architecture = auto` + mirrorlists v3/v4): el pacman
  parcheado de CachyOS detecta la CPU en cada arranque y pacman sirve
  v4 → v3 → genérico según la máquina. Sin tocar ningún fragment.
- Rebranding (`iso_name=cachyosmod`, motd, etiquetas).

---

## Perfiles

Formato: **`<escritorio>-<kernel>-<apps>`**

| Dimensión | Opciones | Descripción |
|-----------|----------|-------------|
| Escritorio | `kde`, `gnome`, `xfce` | KDE Plasma (default CachyOS), GNOME o Xfce |
| Kernel | `default`, `bore`, `lts` | `linux-cachyos` (EEVDF, ISO oficial), `linux-cachyos-bore` (BORE real) o `linux-cachyos-lts` — todos con nvidia-open y zfs |
| Apps | `complete`, `minimal` | `complete` = rescue/extra de CachyOS; `minimal` = solo base |
| Optimización CPU | `generic`, `v3`, `v4`, `v3v4` | Repos oficiales optimizados: `generic` = x86-64 universal; `v3` = AVX2 (Haswell+/Zen+); `v4` = AVX-512 (Skylake-X/Zen 4+); `v3v4` = ambos en cascada v4 → v3 → genérico |

> La optimización CPU **no** es parte del nombre del perfil: se elige con
> `ARCH_TUNE` (local) o el input `arch` (Actions) y se refleja en el nombre
> del archivo ISO/artifact (`cachyosmod-<perfil>-<arch>-<fecha>`).

Ejemplos: `kde-default-complete`, `gnome-lts-minimal`, `xfce-bore-complete`.
Perfiles disponibles: 3 escritorios × 3 kernels × 2 apps = **18**.

> ⚠️ **Requisito de CPU (paquetes horneados):** una ISO `v3` solo arranca en
> CPUs con AVX2 (Intel Haswell 2013+ / AMD Zen+); `v4` requiere AVX-512
> (Intel Skylake-X/Xeon / AMD Zen 4+). En CPUs más viejas el sistema crashea
> (instrucción ilegal). `generic` arranca en cualquier x86-64.
>
> ℹ️ **Selección en runtime (estilo CachyOS oficial):** en builds `v3`/`v4`/
> `v3v4`, el `pacman.conf` del sistema live — que el sistema instalado
> hereda — usa el mismo mecanismo que un CachyOS oficial instalado:
> `Architecture = auto` + secciones `[cachyos-v4]`/`[cachyos-v3]` con
> `Include = /etc/pacman.d/cachyos-vN-mirrorlist`. El pacman parcheado de
> CachyOS (incluido en la ISO como `cachyos/pacman`) detecta la CPU en cada
> arranque y descarta solo los niveles no soportados, así `pacman -Syu`
> mantiene el sistema en el mejor nivel posible para esa máquina.

---

## Estructura del repo

```
CachyOSMod/
├── .github/workflows/build-iso.yml   # Build en GitHub Actions (matriz)
├── overlay/archiso/                   # Modificaciones encimadas sobre la base
│   ├── profiledef.sh                  # Rebranding (iso_name, etiqueta, publisher)
│   ├── packages_base.x86_64           # Paquetes compartidos (base + paru/base-devel + gamemode)
│   ├── packages_desktop-kde.x86_64    # KDE Plasma + plasmalogin
│   ├── packages_desktop-gnome.x86_64  # GNOME + gdm
│   ├── packages_desktop-xfce.x86_64   # Xfce + lightdm
│   ├── packages_kernel-default.x86_64 # linux-cachyos (EEVDF, ISO oficial)
│   ├── packages_kernel-bore.x86_64    # linux-cachyos-bore (BORE real)
│   ├── packages_kernel-lts.x86_64     # linux-cachyos-lts (+nvidia-open, zfs)
│   ├── packages_apps-complete.x86_64  # Apps extra/rescue
│   ├── packages_apps-minimal.x86_64   # (minimal)
│   └── airootfs/etc/cachyosmod-release
├── scripts/
│   ├── build.sh                       # Clona base + overlay + construye
│   └── util-iso.sh                    # util-iso.sh multi-perfil (reemplaza al original)
├── .gitignore
└── README.md
```

---

## Paquetes destacados de la base

La base deriva de la lista oficial de CachyOS, recortada para usuario común
(48 paquetes retirados: red servidor/legacy, guests de VM, accesibilidad,
WWAN, diagnóstico CLI, red compartida — ver commits `5612d3b` y `7843b46`).
Incluye además:

- `cachyos-settings` (+ `cachyos-hello`, keyrings, mirrorlists, Calamares)
- `gamemode` (todos los perfiles)
- `paru` + grupo `base-devel` → **soporte AUR** desde la live
  (`paru -S spotify`, etc.)
- `firefox`, `multilib` habilitado (Steam/Wine 32 bits)

**Nunca quitar de la base:** `mkinitcpio-archiso` (mkarchiso lo necesita en el
chroot para el initramfs live; el build falla sin él).

---

## Construcción local (en Arch Linux)

Requisitos: Arch Linux (o derivado) con sudo, `git`, `rsync`.

```bash
# 1. Instalar dependencias de build
sudo pacman -Syu --needed archiso mkinitcpio-archiso squashfs-tools grub git rsync

# Añadir repo de CachyOS (para cachyos-keyring y paquetes cachyos-*)
sudo pacman-key --init
sudo pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
sudo pacman-key --lsign-key F3B607488DB35A47
# añade a /etc/pacman.conf antes de [core]:
#   [cachyos]
#   Server = https://mirror.cachyos.org/repo/$arch/$repo
sudo pacman -Syu --needed cachyos-keyring

# 2. Construir un perfil concreto
./scripts/build.sh kde-default-complete

# Con optimizacion CPU (repos oficiales v3/v4/v3v4)
ARCH_TUNE=v3v4 ./scripts/build.sh xfce-bore-minimal

# La ISO queda en:  .work/base/out/kde-default-complete/
```

> `build.sh` clona la base de CachyOS en `.work/base/` (fijada a `BASE_REF`),
> aplica `overlay/`, instala `scripts/util-iso.sh` y ejecuta `buildiso.sh`.

Variables opcionales:
- `BASE_REF`: commit de CachyOS-Live-ISO a usar.
- `BASE_REPO`: fork alternativo del repo base.
- `ARCH_TUNE`: `generic` (default) | `v3` | `v4` | `v3v4`. Controla qué nivel
  se **hornea** en la ISO y qué secciones v3/v4 lleva el `pacman.conf` del
  live para la selección en runtime (estilo oficial).

```bash
BASE_REF=<otro-commit> ./scripts/build.sh gnome-lts-complete
```

---

## Construcción en GitHub Actions

Workflow: `.github/workflows/build-iso.yml`.

- **Manual (`workflow_dispatch`)**: elige `desktop`, `kernel`, `apps` y `arch`
  en la UI, o marca **`build_all`** para construir los 18 perfiles en matriz
  (todos con el mismo `arch` elegido).
- **Push a `main`/`master`**: construye el perfil por defecto
  `kde-default-complete` (arch `generic`).
- **`arch=v4|v3v4` en CI**: el runner necesita **AVX-512** (el build ejecuta
  los binarios v4 en chroot durante la instalacion); el workflow lo verifica
  al empezar y falla con un mensaje claro si la CPU no lo soporta.

Cada perfil genera un artifact `cachyosmod-<perfil>[-<arch>]-<fecha>` con la ISO y
su `.sha256` (el sufijo `-<arch>` solo aparece si `arch` no es `generic`;
ej. `cachyosmod-xfce-bore-minimal-v3v4-261018`).

### Cómo usarlo

1. Sube este repo a GitHub.
2. Pestaña **Actions** → **Build CachyOSMod ISO** → **Run workflow**.
3. Selecciona escritorio / kernel / apps / arch (o `build_all`).
4. Descarga el artifact al terminar.

> Los builds usan contenedor `--privileged` (ya configurado) porque `mkarchiso`
> necesita loop-devices y montajes.

---

## Personalizaciones

### Añadir/quitar aplicaciones

- **Apps extra** (solo perfil `complete`): `overlay/archiso/packages_apps-complete.x86_64`.
- **Apps siempre presentes**: `overlay/archiso/packages_apps-minimal.x86_64`.
- **Base compartida**: `overlay/archiso/packages_base.x86_64`.
- **Un escritorio concreto**: su `packages_desktop-<de>.x86_64`.

### Paquetes de AUR

La ISO ya trae `paru` + `base-devel`, así que el AUR funciona en el sistema
instalado/live. Pero **`mkarchiso` solo instala desde repos pacman**: si
quieres un paquete AUR **preinstalado en la ISO**, hay que empaquetarlo antes:

1. Crear un **repo personal** (`.pkg.tar.zst` + `repo-add`) y añadirlo a
   `overlay/archiso/pacman.conf` (copia el de la base y edítalo).
2. O compilar los `.pkg.tar.zst` en CI e instalarlos con un hook de `airootfs`
   (más avanzado).

### Branding

- `overlay/archiso/profiledef.sh`: `iso_name`, `iso_label`, `iso_publisher`.
- Motd: función `generate_motd` en `scripts/util-iso.sh`.
- Menú de arranque / wallpaper: archivos bajo `overlay/archiso/airootfs/`.

### Avanzar la base CachyOS

Cambia `BASE_REF` en `scripts/build.sh` por el commit deseado de
https://github.com/CachyOS/CachyOS-Live-ISO/commits/master. Si CachyOS cambia
`util-iso.sh` de forma importante, revisa la compatibilidad con nuestra versión.

---

## Notas y limitaciones

- **No se puede probar el build en Windows**: `mkarchiso` necesita Linux con
  sudo, loop-devices y privilegios. El build se hace en Arch o en GitHub Actions.
- Revisa los **nombres de paquetes** de los fragments GNOME/Xfce antes del
  primer build (`gdm`, `gnome-shell`, `lightdm`, `xfce4` grupo, etc.).
- La ISO `complete` es pesada (kernels nvidia-open + zfs y apps rescue). Usa
  `minimal` para algo más ligero.

## Licencia

Los scripts derivados de CachyOS-Live-ISO conservan su licencia (GPL). La base
CachyOS es de sus respectivos autores.

