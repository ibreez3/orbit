#!/bin/bash
set -eu

saved_tty=$(stty -g)
cleanup() {
    printf '\033[?2026l\033[?1000l\033[?1006l\033[?2004l\033[?1049l'
    stty "$saved_tty"
}
trap cleanup EXIT
trap 'exit 0' INT TERM
stty -echo

if [ "${1:-}" != "--selection" ]; then
    printf '\033[?1049h\033[?1000h\033[?1006h\033[?2004h'
fi
printf '\033[2J\033[5;5HORBIT_SELECTION\r\n中文 日本語 한국어 café\r\n'
sleep 0.3
for ((i=0; i<400; i++)); do
    printf '\033[?2026h\033[8;1HERROR: fixture frame %04d\033[K\033[?2026l' "$i"
    sleep 0.05
done
