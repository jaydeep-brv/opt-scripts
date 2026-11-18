#!/usr/bin/env bash
# Read-only Ubuntu CVE audit for CVE-2026-111183 and CVE-2026-34000.
# Advisory data snapshot: 2026-11-18. No package changes or network access.
# The only filesystem change is optional self-deletion when run from a script file.

set -u
export LC_ALL=C

SELF_PATH=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    SELF_PATH="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || true)"
fi

cleanup() {
    if [[ -n "$SELF_PATH" && -f "$SELF_PATH" ]]; then
        rm -f -- "$SELF_PATH"
    fi
}
trap cleanup EXIT

if [[ -t 1 ]]; then
    RED=$'\033[31m'
    GREEN=$'\033[32m'
    YELLOW=$'\033[33m'
    RESET=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; RESET=""
fi

red()    { printf '%s[RED]%s %s\n' "$RED" "$RESET" "$*"; }
green()  { printf '%s[GREEN]%s %s\n' "$GREEN" "$RESET" "$*"; }
yellow() { printf '%s[REVIEW]%s %s\n' "$YELLOW" "$RESET" "$*"; }

RED_COUNT=0
GREEN_COUNT=0
REVIEW_COUNT=0

OS_ID="unknown"
OS_VERSION="unknown"
if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
fi

get_installed_version() {
    local pkg="$1" status version
    status="$(dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null || true)"
    [[ "$status" == ii* ]] || return 1
    version="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || true)"
    [[ -n "$version" ]] || return 1
    printf '%s' "$version"
}

# policy can be a Debian version threshold, VULNERABLE, or REVIEW.
audit_package() {
    local cve="$1" label="$2" pkg="$3" policy="$4" version="$5"

    if ! version="$(get_installed_version "$pkg")"; then
        green "$cve | $label | $pkg is not installed"
        GREEN_COUNT=$((GREEN_COUNT + 1))
        return
    fi

    if [[ "$policy" == "VULNERABLE" ]]; then
        red "$cve | $label | $pkg $version — vendor currently marks this Ubuntu release vulnerable; no fixed version is listed"
        RED_COUNT=$((RED_COUNT + 1))
        return
    fi

    if [[ "$policy" == "REVIEW" ]]; then
        yellow "$cve | $label | $pkg $version — release/package mapping unavailable; manual vendor verification required"
        REVIEW_COUNT=$((REVIEW_COUNT + 1))
        return
    fi

    if dpkg --compare-versions "$version" ge "$policy"; then
        green "$cve | $label | $pkg $version — meets fixed-version threshold $policy"
        GREEN_COUNT=$((GREEN_COUNT + 1))
    else
        red "$cve | $label | $pkg $version — below fixed-version threshold $policy"
        RED_COUNT=$((RED_COUNT + 1))
    fi
}

# Canonical package-level fixed versions for CVE-2026-111183, as published
# for Ubuntu releases on 2026-11-18. 26.04 and 24.04 Good Plugins remain
# listed as Vulnerable in Canonical's tracker at this advisory snapshot.
get_good_policy() {
    case "${OS_ID}:${OS_VERSION}" in
        ubuntu:26.04|ubuntu:24.04) printf 'VULNERABLE' ;;
        ubuntu:26.10) printf '1.28.7-1ubuntu0.1' ;;
        ubuntu:22.04) printf '1.20.3-0ubuntu1.11' ;;
        ubuntu:20.04) printf '1.16.3-0ubuntu1.3+esm5' ;;
        ubuntu:18.04) printf '1.14.5-0ubuntu1~18.04.3+esm5' ;;
        ubuntu:16.04) printf '1.8.3-1ubuntu0.5+esm5' ;;
        *) printf 'REVIEW' ;;
    esac
}

get_base_policy() {
    case "${OS_ID}:${OS_VERSION}" in
        ubuntu:26.10) printf '1.28.7-1ubuntu0.1' ;;
        ubuntu:26.04) printf '1.28.2-1ubuntu0.2' ;;
        ubuntu:24.04) printf '1.24.2-1ubuntu0.6' ;;
        ubuntu:22.04) printf '1.20.1-1ubuntu0.8' ;;
        ubuntu:20.04) printf '1.16.3-0ubuntu1.4+esm4' ;;
        ubuntu:18.04) printf '1.14.5-0ubuntu1~18.04.3+esm5' ;;
        ubuntu:16.04) printf '1.8.3-1ubuntu0.3+esm6' ;;
        *) printf 'REVIEW' ;;
    esac
}

#printf '\nCVE READ-ONLY AUDIT | Snapshot: 2026-11-18\n'
printf 'Host: %s | OS: %s %s | Execution: %s\n' "$(hostname 2>/dev/null || echo unknown)" "$OS_ID" "$OS_VERSION" "$(if [[ $EUID -eq 0 ]]; then echo root; else echo unprivileged; fi)"
#printf '%s\n' 'No package installation, upgrade, removal, service restart, or network operation will be performed.'
printf '%s\n' '--------------------------------------------------------------------------'

#printf '\nCVE-2026-111183 | GStreamer RTP depayloader\n'
#GOOD_POLICY="$(get_good_policy)"
#BASE_POLICY="$(get_base_policy)"
#audit_package 'CVE-2026-111183' 'GStreamer Good' 'gstreamer1.0-plugins-good' "$GOOD_POLICY" ''
#audit_package 'CVE-2026-111183' 'GStreamer Base' 'gstreamer1.0-plugins-base' "$BASE_POLICY" ''

printf '\nCVE-2026-34000 | X.Org XKB geometry processing\n'
# Upstream fixed versions. Restrict this comparison to Ubuntu hosts; other
# distributions need their own vendor package advisories.
if [[ "$OS_ID" == 'ubuntu' ]]; then
    audit_package 'CVE-2026-34000' 'X.Org Server' 'xserver-xorg-core' '2:21.1.22' ''
    audit_package 'CVE-2026-34000' 'Xwayland' 'xwayland' '2:24.1.10' ''
else
    audit_package 'CVE-2026-34000' 'X.Org Server' 'xserver-xorg-core' 'REVIEW' ''
    audit_package 'CVE-2026-34000' 'Xwayland' 'xwayland' 'REVIEW' ''
fi

printf '\n============================= FINAL RESULT =============================\n'
printf 'GREEN checks: %d | RED checks: %d | REVIEW checks: %d\n' "$GREEN_COUNT" "$RED_COUNT" "$REVIEW_COUNT"
if (( RED_COUNT > 0 )); then
    red 'OVERALL: ACTION REQUIRED — one or more packages are below/within a vulnerable vendor status.'
elif (( REVIEW_COUNT > 0 )); then
    yellow 'OVERALL: REVIEW REQUIRED — at least one package could not be classified safely.'
else
    green 'OVERALL: NO FLAGGED VULNERABLE PACKAGES FOUND.'
fi
#printf '%s\n' 'Note: RED means the package needs remediation/vendor verification; it does not prove runtime exploitability.'
printf '%s\n' '========================================================================'

if [[ -z "$SELF_PATH" ]]; then
    printf '%s\n' 'SELF-DELETE: Not possible (script was not launched from a regular file, e.g. stdin/pipe).'
fi

exit 0
