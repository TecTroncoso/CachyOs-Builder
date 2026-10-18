# CachyOSMod

ISOs personalizadas construidas sobre la **base 100% CachyOS**
([CachyOS/CachyOS-Live-ISO](https://github.com/CachyOS/CachyOS-Live-ISO)),
con un sistema de **perfiles compuestos** (escritorio × kernel × aplicaciones)
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
- Perfiles **compuestos** `<escritorio>-<kernel>-<apps>`.
- Composición de `packages.x86_64` a partir de *fragments*.
- Selección de display-manager según el escritorio.
- Rebranding (`iso_name=cachyosmod`, motd, etiquetas).

---

## Perfiles

Formato: **`<escritorio>-<kernel>-<apps>`**

| Dimensión | Opciones | Descripción |
|-----------|----------|-------------|
| Escritorio | `kde`, `gnome`, `xfce` | KDE Plasma (default CachyOS), GNOME o Xfce |
| Kernel | `bore`, `lts` | `linux-cachyos` (BORE) o `linux-cachyos-lts` (+ nvidia-open y zfs) |
| Apps | `complete`, `minimal` | `complete` = rescue/extra de CachyOS; `minimal` = solo base |

Ejemplos: `kde-bore-complete`, `gnome-lts-minimal`, `xfce-bore-complete`.
Perfiles disponibles: 3 escritorios × 2 kernels × 2 apps = **12**.

---

## Estructura del repo

```
CachyOSMod/
├── .github/workflows/build-iso.yml   # Build en GitHub Actions (matriz)
├── overlay/archiso/                   # Modificaciones encimadas sobre la base
│   ├── profiledef.sh                  # Rebranding (iso_name, etiqueta, publisher)
│   ├── packages_base.x86_64           # Paquetes compartidos (base)
│   ├── packages_desktop-kde.x86_64    # KDE Plasma + plasmalogin
│   ├── packages_desktop-gnome.x86_64  # GNOME + gdm
│   ├── packages_desktop-xfce.x86_64   # Xfce + lightdm
│   ├── packages_kernel-bore.x86_64    # linux-cachyos (+nvidia-open, zfs)
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
./scripts/build.sh kde-bore-complete

# La ISO queda en:  .work/base/out/kde-bore-complete/
```

> `build.sh` clona la base de CachyOS en `.work/base/` (fijada a `BASE_REF`),
> aplica `overlay/`, instala `scripts/util-iso.sh` y ejecuta `buildiso.sh`.

Variables opcionales:
- `BASE_REF`: commit de CachyOS-Live-ISO a usar.
- `BASE_REPO`: fork alternativo del repo base.

```bash
BASE_REF=<otro-commit> ./scripts/build.sh gnome-lts-complete
```

---

## Construcción en GitHub Actions

Workflow: `.github/workflows/build-iso.yml`.

- **Manual (`workflow_dispatch`)**: elige `desktop`, `kernel` y `apps` en la UI,
  o marca **`build_all`** para construir los 12 perfiles en matriz.
- **Push a `main`/`master`**: construye el perfil por defecto `kde-bore-complete`.

Cada perfil genera un artifact `cachyosmod-<perfil>-<fecha>` con la ISO y su
`.sha256`.

### Cómo usarlo

1. Sube este repo a GitHub.
2. Pestaña **Actions** → **Build CachyOSMod ISO** → **Run workflow**.
3. Selecciona escritorio / kernel / apps (o `build_all`).
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

`mkarchiso` solo instala desde repos pacman. Para meter paquetes AUR:
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

