#!/usr/bin/env bash
set -eu

case "${1:-}" in
    --home-internal-native-vm-capability)
        case "${HOME_FAKE_MODE:-}" in
            query-fail) exit 7 ;;
            disabled) printf 'disabled\n' ;;
            invalid-response) printf 'unknown\n' ;;
            *) printf 'enabled\n' ;;
        esac
        ;;
    run)
        case "${HOME_FAKE_MODE:-}" in
            probe-no-marker) printf 'wrong marker\n' ;;
            probe-marker-then-fail) printf '__home_rt_probe_ok__\n'; exit 7 ;;
            *) exit 7 ;;
        esac
        ;;
    *) exit 7 ;;
esac
