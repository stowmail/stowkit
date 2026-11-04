#!/usr/bin/env bash
# Starts or stops two local Dovecot servers for the generic IMAP track
# (briefs/generic-imap.md), with Apple's `container` tool:
#   full: every extension, SASL PLAIN; 127.0.0.1:31143 (plain text, for the
#         debug-only loopback endpoint, D-471) and 127.0.0.1:31993 (TLS with a
#         self-signed certificate Stow must refuse, D-570 item 4)
#   bare: IMAP4rev1 only and no SASL PLAIN, so Stow uses LOGIN; 127.0.0.1:32143
# Mail is the synthetic fixtures (Tests/Fixtures/eml, D-018), copied into each
# container at start, so a restart gives a fresh mailbox.
#
#   scripts/dovecot-test.sh start
#   STOW_DOVECOT=1 swift test --filter DovecotTests
#   scripts/dovecot-test.sh stop
set -euo pipefail
cd "$(dirname "$0")/.."

image="docker.io/dovecot/dovecot:2.3.21"
seed="${TMPDIR:-/tmp}/stow-dovecot-seed"

stop() {
    for name in stow-dovecot-full stow-dovecot-bare; do
        container delete --force "$name" >/dev/null 2>&1 || true
    done
}

case "${1:-}" in
start)
    stop
    [ -f Tests/Fixtures/eml/manifest.json ] || scripts/make-fixtures
    /bin/rm -rf "$seed"
    box="$seed/sam.taylor/Maildir"
    files=(Tests/Fixtures/eml/*.eml)
    n=0
    for file in "${files[@]}"; do
        n=$((n + 1))
        case $((n % 6)) in
            0) folder=".Archive.2025" ;;
            1) folder=".Sent" ;;
            2) folder=".Trash" ;;
            3) folder=".Junk" ;;
            *) folder="" ;;
        esac
        flags=$([ $((n % 3)) -eq 0 ] && echo "S" || echo "")
        mkdir -p "$box/$folder/cur" "$box/$folder/new" "$box/$folder/tmp"
        cp "$file" "$box/$folder/cur/$((1700000000 + n)).fixture$n.stow:2,$flags"
    done
    for variant in full bare; do
        ports=(-p 127.0.0.1:32143:143)
        [ "$variant" = full ] && ports=(-p 127.0.0.1:31143:143 -p 127.0.0.1:31993:993)
        container run -d --name "stow-dovecot-$variant" "${ports[@]}" \
            -v "$seed:/seed" -v "$PWD/Tests/Dovecot:/etc/stow" "$image" \
            sh -c "cp -a /seed/. /srv/mail/ && chown -R 1000:1000 /srv/mail && exec dovecot -F -c /etc/stow/$variant.conf" >/dev/null
    done
    sleep 3
    echo "Dovecot: full on 127.0.0.1:31143 and :31993, bare on 127.0.0.1:32143 ($n synthetic messages)."
    ;;
stop)
    stop
    /bin/rm -rf "$seed"
    ;;
*)
    echo "usage: $0 start|stop" >&2
    exit 2
    ;;
esac
