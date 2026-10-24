# Packaging Guide

This guide describes the cross-distribution packaging flow backed by `script-helpers`.

## Folder structure (consumer repo)

```
./
  debian/
  packaging/
    packaging.env
    README.md
    rpm/
      myapp.spec
      build/
    arch/
      PKGBUILD
    brew/
      myapp.rb
```

## Scaffold the files

Commands assume script-helpers is the submodule at `scripts/script-helpers`, as the README sets it up; use your own path if the repository keeps it elsewhere.

```
./scripts/script-helpers/scripts/packaging_init.sh --repo .
```

Edit `packaging/packaging.env` and rerun the command to re-render templates.
Dependencies use `|` as a separator to preserve spaces in version constraints.

## Build commands

- Debian (.deb): `./scripts/script-helpers/scripts/build_deb_artifacts.sh --repo .`
- RPM (.rpm): `./scripts/script-helpers/scripts/build_rpm_artifacts.sh --repo .`
- Arch (.pkg.tar.zst): `./scripts/script-helpers/scripts/build_arch_artifacts.sh --repo .`
- Homebrew tarball: `./scripts/script-helpers/scripts/build_brew_tarball.sh --name myapp --repo .`

## Homebrew formula

```
./scripts/script-helpers/scripts/gen_brew_formula.sh --name myapp --desc "My app" --homepage https://example.com --tarball dist/myapp-1.0.0.tar.gz --url https://example.com/myapp-1.0.0.tar.gz
```

## Signing notes

- Debian/PPA: use `debuild -S -sa -k<keyid>` and set `PPA_GPG_PASSPHRASE`.
- RPM: configure `~/.rpmmacros` with `%_gpg_name` and run `rpmsign --addsign`.
- Arch: use `makepkg --sign` (requires `PACKAGER` + GPG key).
- Homebrew: formula updates are signed by git commit in the tap repo.

## Publish commands

- PPA (Launchpad): `./scripts/script-helpers/scripts/ppa_upload.sh --repo . --ppa ppa:owner/name --key-id ABCDEF`
- Homebrew tap: `./scripts/script-helpers/scripts/publish_homebrew.sh --formula packaging/brew/myapp.rb --tap-repo owner/homebrew-example`

## End-user install commands

- Debian (PPA): `sudo add-apt-repository ppa:OWNER/NAME && sudo apt update && sudo apt install myapp`
- RPM (local): `sudo dnf install ./myapp-<ver>.rpm`
- Arch (local): `sudo pacman -U ./myapp-<ver>.pkg.tar.zst`
- Homebrew: `brew tap OWNER/tap && brew install myapp`
