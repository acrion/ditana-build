#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Replace the production repository with what the testing repository holds.
#
# This is what "released" means, and it is in libexec/ rather than bin/ because
# calling it directly releases without recording that it happened: the run
# record is stamped by the caller, and run by hand there is no caller.
#
# Each server keeps its repositories under a document root, with `ditana` a
# symlink into `versions/`. The new set is copied beside the current one and
# the symlink is moved, so that no client ever sees a half-copied repository --
# the switch is one rename. The directory that was current is deleted
# afterwards.

set -e

BUILD_CONF=${DITANA_BUILD_CONF:-/etc/ditana/package-build.conf}
[[ -r $BUILD_CONF ]] || { echo "$BUILD_CONF is missing" >&2; exit 1; }
# shellcheck source=/dev/null
source "$BUILD_CONF"
[[ -n ${DITANA_SERVERS:-} ]] || {
    echo "DITANA_SERVERS is not set in $BUILD_CONF. It names the hosts this" >&2
    echo "repository is published to, as a space-separated list of" >&2
    echo "user@host:/document-root." >&2
    exit 1
}

for SERVER in $DITANA_SERVERS; do
    ssh "${SERVER%%:*}" bash << EOF
        set -e
        BASE_DIR="${SERVER##*:}"
        CURRENT_LINK_TARGET=""

        if [[ -L "\${BASE_DIR}/ditana" ]]; then
            CURRENT_LINK_TARGET="\$(readlink -f "\${BASE_DIR}/ditana")"
        else
            echo "Error: \${BASE_DIR}/ditana is not a symbolic link or a directory"
            exit 1
        fi

        # Whether this release would change anything at all, asked of rsync
        # itself and with the criteria the copy below uses -- so the question
        # and the answer cannot drift apart. Empty output means every file is
        # already there, unchanged, and none is left over.
        #
        # A nightly run that rebuilt nothing produces exactly this, and without
        # the check it copied a gigabyte and a half into a new directory,
        # moved the symlink and deleted the old tree, every night, for no
        # difference. A client downloading from the tree that was current at
        # that moment loses it.
        #
        # Anything unexpected in that output releases rather than skips: the
        # cost of releasing needlessly is a copy, the cost of skipping wrongly
        # is a production repository that stays behind for good.
        if [[ -z "\$(rsync -rni --delete "\${BASE_DIR}/ditana-testing/" "\${CURRENT_LINK_TARGET}/")" ]]; then
            echo "\${BASE_DIR}: production already holds this set, nothing to release."
            exit 0
        fi

        NEW_DIR="\$(mktemp -d "\${BASE_DIR}/versions/ditana.XXXXXXXX")"
        rsync -avh --progress "\${BASE_DIR}/ditana-testing/" "\${NEW_DIR}/"

        ln -sfn "\${NEW_DIR}" "\${BASE_DIR}/ditana"
        rm -rf "\${CURRENT_LINK_TARGET}"
EOF
done
