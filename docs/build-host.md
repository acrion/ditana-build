# Setting up a build host

What is required to set up a Ditana build host from a fresh installation, in the sequence it must occur. `README.md` describes what this pipeline accomplishes and the rationale behind it; this page serves as the recipe.

Read it once prior to beginning. Several of the steps below cannot be done afterwards without repeating work, and one of them cannot be detected as missing at all.

## What the host ends up holding

A build host is not a checkout. Beside this repository it carries a package tree, a chroot, a signing key, two kinds of SSH access, and – if it is to test what it built – a second checkout with an installation medium in it. None of that comes with the repository, and most of it is either large or secret.

## Packages the host needs

    pacman -S --needed devtools pacman-contrib git rsync \
                       qemu-base edk2-ovmf mtools imagemagick

`devtools` supplies `mkarchroot`, `arch-nspawn` and `makechrootpkg`, and `pacman-contrib` supplies `repo-add`; without these `setup-buildroot` halts prior to doing anything. The remainder is part of the test installation and is required solely on a host that carries out one. `rakudo-bin` and `zef` are needed only to build an installation medium on this host.

## The build user

The pipeline never runs as root. It works in the build user's clones, signs with that user's key and connects to the servers using that user's SSH key; running it as root would change the ownership of everything it interacts with.

That user must belong to `wheel`, since the chroot is accessed via two pinned `sudo` rules that `setup-buildroot` sets up. It must also be able to write `/dev/kvm` if the host is to test what it has built – on the reference host, this is a device mode of `0666` rather than group membership, so a machine with stricter udev rules requires the user to be in the `kvm` group instead.

## The package tree

    setup-package-clones /path/to/packages
    set-clone-mtimes     /path/to/packages

The first creates one git clone for each entry in `packages.tsv`, with the remote names the pipeline pulls with. It takes a `--dry-run` option that shows what it would perform. The second gives every clone file timestamps matching the age of its content: git records no modification times, so in a fresh clone each recipe looks newer than the artefact next to it and the pipeline would rebuild everything.

Cloning reaches the AUR, GitHub and the Arch packaging GitLab via the network, and the GitHub clones need an SSH key that GitHub accepts.

## The seed, and the one file nobody notices is missing

Copy from a host that already has them:

- every `*.pkg.tar.zst` and its `.sig`, into the package directory it belongs to;
- the `SRCDEST` cache named in the build user's `makepkg.conf`;
- **`.pkgbuild-review-state.json`, which sits beside the package directories.**

The first two are a matter of time: without them the initial run rebuilds every package in `packages.tsv` and takes days.

The third point hinges on trust, and it is the sole item on this page that fails silently. That file records, per package, the last upstream commit a person reviewed. When it is absent, the review gate takes the current `HEAD` as the starting point and records it as reviewed – which is correct on the host that has been shipping that commit, and wrong on a new one, where clones are freshly pulled from upstream. Everything upstream changed since the last review is then considered accepted, and no run emits any unusual reports. Copy the file, or review every package by hand.

## The chroot

    setup-buildroot /path/to/packages          # escalates on its own

It refuses to continue when the build user is not in `wheel`, and, on a host that holds the signing key, when the host's pacman keyring does not trust that key. Both would otherwise only surface inside a container, hours into a build.

What it leaves behind: the chroot under `/var/lib/`, a package cache of its own under `/var/cache/`, `/etc/ditana/pacman-buildroot.conf` (the chroot's own pacman configuration, which is why the host's is never touched), the two `sudo` rules, `/etc/ditana/package-build.conf`, and an empty staging repository in the package tree.

The host's own `/etc/pacman.conf` needs the Ditana repository to be configured and synchronized as well. The review gate resolves newly added dependencies against the host, not against the chroot, and without it a dependency on another Ditana package looks unsatisfiable.

## Where it publishes

`setup-buildroot` writes `/etc/ditana/package-build.conf` and preserves the two values it cannot derive:

    DITANA_SERVERS="root@one.example:/var/www/example.org root@two.example:/srv/www"
    BUILD_HOST=""

Nothing is published while the first is empty: the pipeline stops and names the setting instead of uploading to nowhere and reporting success. `BUILD_HOST` is for the arrangement in which the key and the build live on different machines, and names the host whose artefacts are fetched.

Two conditions must hold on every server prior to the initial execution, and neither is created by anything in this code. `<document-root>/ditana-testing/x86_64/` must exist, since the testing repository is emptied before it is populated and attempting to empty a directory that does not exist halts the run. And `<document-root>` must contain `versions/` as a directory with `ditana` as a symlink pointing into it, because a release consists of a copy adjacent to the current tree followed by one rename.

The user in `DITANA_SERVERS` must accept this host's SSH key without a passphrase, and its host key must already be in `known_hosts`: an unattended run cannot respond to a prompt. When the unattended unit is used, that connection is made as root, so the key belongs to root rather than to the build user.

## Signing

A host that signs needs the signing subkey in the build user's keyring, without a passphrase, and the primary key it belongs to in the host's pacman keyring at full trust. The subkey is produced where the primary key lives:

    export-signing-subkey <subkey-fingerprint> subkey.gpg

and imported here. The passphrase cannot be taken off afterwards on this side: once only a subkey has been imported, `gpg --passwd` resolves to the primary key, finds a stub and fails. `README.md` describes the order the changeover has to follow.

A host that does not sign runs `build-ditana-packages --build-only`, holds no key at all, and a second machine publishes what it produced.

## Testing what was built

The release is gated on installing the repository that was just built, so a host that releases needs a medium to install from and a machine to install it in.

Check out the installer repository beside this one and build a testing medium from its `main` branch:

    DITANA_BUILD_TESTING_ISO=y ./build.sh

The flag determines whether a medium built from `main` installs from the testing repository rather than the production one. Which repository the guest draws from is a property of the medium, not of the test harness, so a release medium tests the production repository and nothing else.

The harness also requires `/dev/kvm` to be writable, OVMF firmware, and room in `/var/tmp` for two sparse 64 GiB images beside the medium. It forwards the guest's SSH port to `127.0.0.1:2222` and decides the whole release based on what answers there, so nothing else may be listening on that port.

### Refreshing the medium after an installer change

The installer lives on the medium, so a change to it reaches the nightly test only through a new one. The combination the gate needs is not the obvious one, and it is worth stating: **the installer and the configuration users actually have, installing the packages that are about to become production.** That is `main` for both repositories, with the packages coming from testing – and it is exactly what the flag produces. The configuration tag follows the branch and takes `latest` on a `main` build either way, so the flag is the only thing that needs to be remembered.

    cd ~/ditana-installer
    git pull
    DITANA_BUILD_TESTING_ISO=y ./build.sh

Add `--quick` when nothing outside `airootfs/root` changed – it replaces that tree in the existing image instead of rebuilding from scratch, which is minutes rather than half an hour. A change to `build.sh` itself, to the boot entries or to the package list is not one it covers.

Press Enter at the question regarding the signing key rather than choosing one. The medium for this test is built unsigned, and `docs/testing-medium.md` gives the reasons together with everything else that medium has to be.

`ditana-test-install` takes the newest `.iso` in `out/`, and before it starts the guest it reads out of the medium whether it is unsigned, installs from the testing repository and was built from `main`. A medium that is none of this is refused rather than tested, so a release medium left beside the testing one stops the nightly run instead of passing it. Keeping one medium in that directory still spares that night, and `--iso` names the one you mean.

`mkarchiso` must execute as root, and so must the squashfs operation a `--quick` rebuild performs, so `build.sh` uses `sudo` on both execution paths. It also calls `sudo -k` first, deliberately erasing a stored credential – so the build asks for a password even right after another `sudo`. On a host where the build user has passwordless `sudo`, as is the case with the build VM, it proceeds without user intervention; anywhere else, a person must be present at the keyboard.

## The unattended run

    sudo install -m644 systemd/ditana-package-build.service \
                       systemd/ditana-package-build.timer \
                       /etc/systemd/system/
    sudo ln -sf "$PWD/bin/ditana-package-build" /usr/local/bin/
    sudo systemctl daemon-reload
    sudo systemctl enable --now ditana-package-build.timer

The symlink is what the unit calls; without it the unit fails with an exec error and the timer continues ticking every night against nothing.

Before turning on the timer, perform one run manually from the package tree:

    cd /path/to/packages
    ./build-ditana-packages --build-only

The working directory is significant. The staging repository is resolved in relation to it, so a run started elsewhere stages into the incorrect location.

## Coordinating with an automatic system update

**This section applies to a host that performs self-updates automatically. Nothing in this repository depends on it.**

A build must never overlap with a system update. pacman takes a database lock, and a package built halfway through an update of the toolchain it links against is not a package anyone should ship. Worse, an update that installs a kernel and reboots the machine takes a test installation with it – which is not hypothetical, it happened to a run started outside the lock.

The reference host resolves this with a lock that long-running jobs take, and the drop-in beside the unit is what puts the build inside it. Install it too, on such a host only:

    sudo install -d /etc/systemd/system/ditana-package-build.service.d
    sudo install -m644 systemd/ditana-package-build.service.d/*.conf \
                       /etc/systemd/system/ditana-package-build.service.d/
    sudo systemctl daemon-reload

The drop-in replaces the unit’s command rather than wrapping it, because systemd has no way to wrap one, so it repeats the flags. That the two agree is not left to care: it is a case in `ditana-package-build-test`, and a drop-in that has drifted fails it twice.

`--wait` blocks on the lock rather than polling, so a collision costs half an hour at worst instead of a whole day. On a host that does not update itself, or updates itself at a time no build can reach, leave the drop-in out and the unit works as it stands. The pipeline itself never takes that lock and never calls that tool.

The same applies to notifications. Messages pass through `ditana-notify` when that file is present and fall to standard output otherwise, which on an unattended host is the journal.
