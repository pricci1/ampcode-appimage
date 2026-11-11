# Amp AppImage

Unofficial **x86-64 Linux** repack of [Amp](https://ampcode.com), inspired by [AM](https://github.com/ivan-hc/AM).

## Download

Get the AppImage from [Releases](https://github.com/pricci1/ampcode-appimage/releases/latest), then:

```sh
chmod +x Amp-*.AppImage
./Amp-*.AppImage
```

Add `--appimage-extract-and-run` without FUSE. Host desktop libraries and user namespaces are required; sandboxing stays enabled. Ubuntu/AppArmor may need a local policy. For autostart, use the AppImage's permanent path, not Amp's login setting.

## Build

Requires x86-64 Linux, Bash, curl, GnuPG/gpgv, dpkg-deb, and GNU coreutils.

```sh
./build.sh                  # Output: dist/ (AppImage, checksum, provenance)
./build.sh --check-version  # Verify signed metadata and print the current version
```

GitHub Actions checks hourly and publishes new stable versions after signature/checksum verification and build validation. Pushes/PRs build only; **Run workflow** on `main` checks for a release manually. No extra secrets needed. GitHub may disable schedules after 60 days of inactivity.

Updates are manual: download a newer AppImage. This is not an official Amp distribution; Amp's terms still apply.
