# The medium the nightly test installs from

Every night the build host installs the repository it has just built into a virtual machine, and the packages reach users only if that machine boots and answers for itself. Which medium it installs from decides what that answer is about, so it has to be one particular kind of medium, and `ditana-test-install` refuses to take a verdict from any other.

## What it has to be

Three properties, and each of them is a way for a run to look green while having tested something else.

**Unsigned.** mkarchiso signs the rootfs image only when a signing key was chosen at the start of the build, and a key is chosen for a medium that will be published. Such a medium installs from the production repository, so the verdict would be about packages that were released weeks ago.

**Installing from the testing repository.** The installer within the medium must enable ditana-testing, since those are the packages this run built. The name of the ISO does not settle it: build.sh may apply the testing patch to profiledef.sh only, which renames the ISO to Ditana_Testing and leaves the official repository in place.

**Built from main.** The branch decides which configuration the installer downloads, and a main build takes the released one while a branch build takes the branch’s own. The packages being tested are the ones about to be released, so they have to meet the configuration that users have.

## How to build one

On the build host:

    cd ~/ditana-installer
    DITANA_BUILD_TESTING_ISO=y ./build.sh

and press Enter at the question about the signing key rather than choosing one. Nothing has to be copied afterwards: ditana-test-install takes the newest ISO in ~/ditana-installer/out, which is where the build puts it.

Not signing is not a step skipped to save time. build.sh runs the configuration tests, 32 of them and they take their while, only for a signed build, on the reasoning that a signed medium is one that gets published. The medium built here never is. It also matters that those tests need Sparrow6 and Tomty in the Raku installation of the build host, and without them a signed build stops a few minutes in, right after the tests of the installer itself.

One thing a build on this host leaves behind, whether it signs or not: the Ditana key inside the medium is exported afresh from the keyring of the machine that builds, and this host holds the signing subkey alone, because `export-signing-subkey` transfers nothing else. What lands in the medium is then narrower than what the repository carries. It is enough for `pacman`, which needs the primary key and the signing subkey and nothing besides, but it is not the same file, and since that file is versioned it would be committed by accident. After a build:

    git restore airootfs/root/bind-mount/root/ditana-key.asc

## What is checked, and how

ditana-test-install reads the three properties out of the medium itself before it starts the guest, and refuses to run where one of them is missing or cannot be read. A check that could not be carried out is not a check that passed.

The two files that settle the last two properties reside within the rootfs image, and the rootfs image is contained within the ISO. Neither is unpacked: xorriso reports the block where the image begins, and unsquashfs reads a filesystem at an offset, so the data retrieved is a few kilobytes from a 1.9 GB file.

Testing a medium that is none of this stays possible by hand: test-install-in-qemu takes an ISO, an answer file and a working directory, and asks nothing about what it was handed. What it will not do is write a verdict into a run record, and that is what the refusal is about.

The decisions are doctested beside the code. The reading is exercised by ditana-test-install-test, against media it builds itself.
