# ditana-build

The pipeline that builds the [Ditana](https://ditana.org) package repository:
a number of packages, rebuilt from their upstream sources, signed, and published only as
a complete set.

Every run is recorded and published at
**[ditana.org/builds](https://ditana.org/builds/)** — including the runs that
shipped nothing. The underlying records are plain JSON under
[`/build-history/`](https://ditana.org/build-history/index.json).

## Where this comes from

This predates Ditana’s first release. It began around 2023 as a single shell script that built a few packages, and it grew the way such scripts grow: every problem that arose once was answered with a few more lines, until reading it had become harder than running it. Somewhere along that road it was ported to Python. It was never made public – it was the private tooling behind a distribution, and nobody had requested access to it.

What brought it here is the build dashboard. ditana.org/builds makes a claim about every package Ditana ships, and a claim of that kind is worth exactly what its evidence is worth. The records that page reads are written by this pipeline, so the pipeline is part of the evidence.

It is not turnkey, and it is not meant to be. The hosts it publishes to, the paths on them and the key it signs with are properties of one installation; running it as it stands publishes nothing anywhere, and says so. What it is good for is reading: what a small distribution has to do in order to rebuild third-party recipes and still say something honest about the result, in the form that actually runs rather than in the form of an article about it.

## The invariant

The repository is published all-or-nothing. If one package cannot be built, or
its sources cannot be fetched, or the review gate finds something, nothing is
uploaded and nothing is released.

Ditana's claim is that its packages are always mutually consistent, so a
partially updated repository is worse than no update at all. `release_to_production()`
sits after the `try`/`except` in the pipeline, on a path no failure can reach.
That placement is the enforcement, not a comment.

The cost is real and is not hidden: measured against the last twelve months of
upstream history, the review gate stops a run roughly once every three and a
half days. That is the price of the guarantee, not a defect.

## Contents

| Path | Purpose |
|---|---|
| `bin/build-ditana-packages` | The pipeline: pull, review, decide, build, sign, upload, `repo-add` |
| `bin/publish-ditana-build` | Signs and publishes what a keyless build host produced, and releases it |
| `bin/pkgbuild-review-gate` | Classifies what each `git pull` brought in; stops the run for anything not safe by construction |
| `bin/pkgbuild-review-gate-test` | 34 control cases for the gate — 24 attacks, 10 benign changes |
| `bin/makepkg-srcdest-preflight` | Detects cached VCS clones makepkg would refuse, before hours are spent |
| `bin/setup-package-clones` | Creates the package clones with the correct remote layout |
| `bin/set-clone-mtimes` | Gives a fresh clone file times that reflect the age of its content |
| `bin/setup-buildroot` | Prepares a host for chroot builds: chroot, its pacman.conf, the sudo rules |
| `bin/export-signing-subkey` | Exports a signing subkey without its passphrase, for an unattended host |
| `bin/ditana-package-build` | Entry point of the unattended build; drops from root to the build user |
| `bin/ditana-test-install` | Installs the testing repository into a QEMU guest and records the verdict on the run |
| `bin/test-install-in-qemu` | The guest itself: config drive, unattended install, then boot what was installed |
| `bin/test-install-in-qemu-test` | Control for the banner probe, against listeners that are not a guest |
| `bin/inspect-test-install` | Opens the disk a test installation wrote, and closes it again in the right order |
| `bin/release-after-test` | Releases a run to production once its test installation has passed |
| `bin/run-record-test` | Control for the run record: what goes into it, and that it reaches the servers |
| `bin/release-to-production-test` | Control for the release, against a local document root |
| `bin/ditana-test-install-test` | The reading of a medium, against media the test builds itself |
| `bin/systemd-units-test` | Whether the units name only executables the build host has |
| `bin/run-doctests` | The doctests the pipeline scripts carry beside the code they describe |
| `libexec/` | Steps that belong to a tool rather than to a person: releasing testing to production |
| `etc/` | The chroot's pacman.conf template and the sudoers rules `setup-buildroot` installs |
| `packages.tsv` | Directory, remote name and fetch URL of every package clone |
| `systemd/` | Timer and service for the unattended build, plus the optional drop-in that puts it inside a maintenance lock |
| `docs/build-host.md` | How to stand a build host up from a fresh installation |
| `docs/testing-medium.md` | What the medium the nightly test installs from has to be, and how to build one |

## The review gate

Ditana rebuilds third-party AUR PKGBUILDs into a repository its users trust
through pacman's `SigLevel`. The AUR has been under an active supply-chain
attack: orphaned packages were adopted and given malicious commits, which is
why adoption and pushes were disabled in August 2026. At least one packaged
PKGBUILD is orphaned — its `# Maintainer:` line is empty.

So every `git pull` is classified before anything is built. Version and release
bumps, comments, whitespace, `optdepends` text and checksums that accompany a
version change pass. A change to `source=`, to `url=`, to a VCS fragment, to
`install=`, to `provides=`/`conflicts=`/`replaces=`/`validpgpkeys=`, to any
function body, to the maintainer line, or a checksum that changes without a
version, stops the entire run.

The gate never sources the PKGBUILD — sourcing executes the top level of the
very file under suspicion. Everything is derived from a static, quote- and
here-document-aware scan, and it fails closed when the scan is unsure. The
comparison baseline is the last accepted commit, not the previous `HEAD`, so a
finding cannot be buried by a later harmless commit.

**What it does not do:** it reviews packaging metadata, not upstream source
code. For a `-git` package the upstream commit itself is unreviewed by design.

## The build runs in a chroot

Packages are built with `makechrootpkg` in `/var/lib/ditana-buildroot`, whose
own `pacman.conf` carries the Ditana repository. The host's `pacman.conf` is
never touched.

Pointing the host at the testing repository for the duration of a build is a
system-wide change with no reliable undo: `atexit` and `trap` survive an
exception but not an OOM kill, and a file left pointing at testing means the
next automatic system update pulls testing packages into the running system.

A package that has been built and signed is hardlinked into `<packages>/.repo`
and added to the database there. The chroot reaches that directory as a
`file://` repository — `arch-nspawn` bind-mounts every `file://` server it
finds in the chroot's `pacman.conf` by itself — which is how a package builds
against another Ditana package produced minutes earlier. The staging directory
is emptied at the start of every run, so a build can never succeed against a
version that is not going to be published.

The chroot verifies the signature of each of those packages rather than
trusting the local directory. It is the same check a user's pacman performs,
and it is the only point in the pipeline that would notice a package nobody can
install.

The chroot has a package cache of its own, `/var/cache/ditana-buildroot`, and
the host's is deliberately not listed beside it. pacman searches every cache
directory by file name, and a rebuild that keeps its version — a toolchain
rebuild does — produces a different file under the name it had before. Any
stale copy is then rejected against the new checksum and fails the whole
transaction.

`makechrootpkg` calls `makepkg` with `--skipinteg` and `--holdver` and neither
can be switched off from outside, so the pipeline fetches and verifies the
sources on the host first (`makepkg --verifysource`, or `makepkg -od
--noprepare` for VCS packages). Without that, no checksum and no source
signature would be verified anywhere, and the gate's rule that a checksum may
only change together with a version would be guarding nothing.

## Signing, and where the key lives

The machine that builds is the machine that compiles unreviewed upstream code.
It should not also be the machine that can vouch for the result.

Keeping the two apart is therefore an option and not a rule, and which one an installation takes is where its key lives. A build host without a key runs `build-ditana-packages --build-only`: it builds, and holds nothing that could vouch for the result. `publish-ditana-build`, on the machine where the key lives, fetches the artefacts, signs them, assembles the repository database and publishes. A build host that holds the signing subkey does that itself, and buys with it the one thing the split cannot have: a release gated on a test installation of exactly what was just built.

That protects the key, not the packages: the signing machine signs what the
build host produced, sight unseen. What it prevents is a build host that can
have arbitrary data signed at any time.

Packages are signed with a dedicated signing subkey rather than with the
primary key. A subkey can be revoked and replaced on its own — the primary key,
and therefore the fingerprint users trust, stays. It also cannot certify, so it
cannot mint further keys that existing keyrings would accept.

`SIGNING_KEY` in `bin/build-ditana-packages` ends in `!`, which means that key
and no other. Given a primary key or a user id, gpg signs with the newest
signing-capable subkey it can find, so a subkey created on a signing host would
silently take over — before the keyring carrying it has reached a single
installation, and every installation would then reject every package. The `!`
makes the changeover an edit rather than a side effect.

Rolling out a signing subkey is therefore ordered:

1. Create the subkey where the primary key lives.
2. Re-export the keyring package, bump it, and publish it — still signed with
   the previous key.
3. Wait until installations have picked the new keyring up.
4. `export-signing-subkey`, import the result on the signing host, and point
   `SIGNING_KEY` at the subkey.

Step 4 is a script rather than a command because the passphrase cannot be
removed after the fact on the target host: once only a subkey is imported,
`gpg --passwd` resolves to the primary key, finds a stub, and fails. It is
stripped where the primary key lives, in a throwaway keyring on `/dev/shm`, and
the script signs with the result before handing it over.

## Testing that the repository can be installed

A repository that builds, signs and uploads can still be one nobody can install from, and no amount of building catches that. So between the testing repository and the release there is one more step: the build host installs that very repository into a QEMU guest of its own, unattended, driven by an answer file on a small config drive – the same mechanism a hosting provider would use over PXE, which is why no keystrokes are simulated.

The guest must do two things. It must complete the installation, concluding with a reboot; and what was installed must come up on its own and answer on port 22. The second is not a formality: an installation may write every file correctly and still result in a machine that fails to boot. Reaching the banner means the bootloader ran, the initramfs found and imported the ZFS pool, systemd reached multi-user, the network became active and a service started, and nothing is injected into the guest to arrange any of that.

A third outcome is neither of those two, and it used to appear as a hang. An answer file can request something this machine cannot be: a setting that is not available here, or one whose value is determined by another setting. The installer refuses such a file rather than installing a machine nobody requested, and it communicates this on the serial console, which is the sole channel a guest has while it is still running. The harness watches that console and ends the run in seconds with the installer’s own words, instead of enduring its timeout and reporting that the guest never reached its final reboot.

The harness is a script of its own and is worth running by hand on any ISO, which is what Ditana does before a release. It touches no repository, no run record and no server.

    bin/test-install-in-qemu <iso> <answer-file.kdl> [work-dir]

The answer file lives in the installer repository, at
`examples/autoinstall-test-vm.kdl`. It needs `/dev/kvm`, `qemu-system-x86_64`,
`qemu-img`, `mkfs.fat`, `mcopy` and OVMF; `magick` turns the screenshot of a
failed run into a PNG. `DITANA_TEST_INSTALL_TIMEOUT`, `_BOOT_TIMEOUT`,
`_MEMORY`, `_DISK` and `_SSH_PORT` are the knobs.

Which repository the guest installs from is a property of the medium and not of the harness. An ISO built from a branch, or from main with `DITANA_BUILD_TESTING_ISO` set, installs from the testing repository; a release ISO installs from the production one. Testing both means building both and running the harness twice.

The harness records how far it got — `installing`, `installed`, `booted` — and
`ditana-test-install` writes that into the run record, together with the
screen of the guest at the moment it gave up. Both are shown at
[ditana.org/builds](https://ditana.org/builds/).

## Setting up a build host

Standing one up takes more than a checkout: a package tree seeded from a host that already has one, a chroot, a signing key, SSH access to the publish servers, and – for a host that tests what it built – an installation medium to test with. [`docs/build-host.md`](docs/build-host.md) is the
recipe, in the order it has to happen.

One thing there is worth knowing before it bites. The record of which upstream commit was last reviewed for each package lives beside the package tree and in no repository. A host set up without it starts from nothing, accepts whatever upstream happens to be at, and says nothing about it.

## It does not depend on a maintenance mechanism

A build must never overlap with a system update: pacman takes a database lock, and a package built halfway through an update of the toolchain it links against is not a package anyone should ship. Worse, an update that installs a kernel and reboots the machine takes a running test installation with it.

The unit shipped here works on any host; a drop-in next to it, installed only where it is wanted, puts the build inside such a lock. The pipeline itself never takes it and never calls the tool that provides it; notifications go the same way, through a single entry point when it exists and to standard output when it does not. On a host that does not update itself while a build could be running, the lock comes out of the unit and nothing else changes.

## Licence

AGPL-3.0-or-later. Every script carries the SPDX identifier; the full text is
in `LICENSE`.
