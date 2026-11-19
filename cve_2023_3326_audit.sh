#!/usr/bin/env bash
# CVE-2023-3326 read-only exposure audit for Ubuntu
# The script removes its own file on exit when launched from a regular file.
# It does not install, remove, update, or modify system configuration.

set -u
export LC_ALL=C

SELF_PATH=""
if [[ -f "${BASH_SOURCE[0]:-}" ]]; then
    SELF_PATH="$(readlink -f -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
fi

cleanup() {
    if [[ -n "$SELF_PATH" && -f "$SELF_PATH" ]]; then
        rm -f -- "$SELF_PATH" 2>/dev/null || true
        if [[ ! -e "$SELF_PATH" ]]; then
            echo "[INFO] SELF-DELETE: Script file deleted."
        else
            echo "[REVIEW] SELF-DELETE: Could not delete script file: $SELF_PATH"
        fi
    else
        echo "[INFO] SELF-DELETE: Not possible (script was not launched from a regular file)."
    fi
}
trap cleanup EXIT

RED=0
REVIEW=0
GREEN=0
AFFECTED_PACKAGES=()
ACTIVE_FINDINGS=()


pass() { GREEN=$((GREEN + 1)); printf '[GREEN] %s\n' "$*"; }
warn() { REVIEW=$((REVIEW + 1)); printf '[REVIEW] %s\n' "$*"; }
fail() { RED=$((RED + 1)); printf '[RED] %s\n' "$*"; }

is_installed() {
    local status
    status="$(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true)"
    [[ "$status" == "installed" ]]
}

pam_stack_has_module() {
    local module="$1"
    grep -Eqs "^[[:space:]]*[^#].*${module}([[:space:]]|$)" \
        /etc/pam.d/common-auth /etc/pam.d/common-account \
        /etc/pam.d/common-password /etc/pam.d/common-session \
        /etc/pam.d/sshd /etc/pam.d/login /etc/pam.d/gdm-password \
        /etc/pam.d/sudo 2>/dev/null
}

sssd_config_files=()
if [[ -s /etc/sssd/sssd.conf ]]; then
    sssd_config_files+=(/etc/sssd/sssd.conf)
fi
if [[ -d /etc/sssd/conf.d ]]; then
    while IFS= read -r -d '' file; do
        [[ -s "$file" ]] && sssd_config_files+=("$file")
    done < <(find /etc/sssd/conf.d -maxdepth 1 -type f -name '*.conf' -print0 2>/dev/null)
fi

sssd_configured=false
sssd_kerberos_provider=false
if ((${#sssd_config_files[@]} > 0)); then
    if grep -Eiq '^[[:space:]]*domains[[:space:]]*=[[:space:]]*[^[:space:]]' "${sssd_config_files[@]}" 2>/dev/null; then
        sssd_configured=true
    fi
    if grep -Eiq '^[[:space:]]*(auth_provider|id_provider)[[:space:]]*=[[:space:]]*(krb5|ad|ipa)([[:space:]]|$)' "${sssd_config_files[@]}" 2>/dev/null; then
        sssd_kerberos_provider=true
    fi
fi

sssd_runtime_active=false
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet sssd.service 2>/dev/null; then
        sssd_runtime_active=true
    else
        for unit in sssd-pam.socket sssd-pam-priv.socket sssd-nss.socket sssd-pac.socket; do
            if systemctl is-active --quiet "$unit" 2>/dev/null; then
                sssd_runtime_active=true
                break
            fi
        done
    fi
fi

verify_setting=""
if [[ -r /etc/krb5.conf ]]; then
    # Read the value only from the [libdefaults] section.
    verify_setting="$(awk '
        BEGIN { in_section=0 }
        /^[[:space:]]*\[/ {
            in_section = (tolower($0) ~ /^[[:space:]]*\[libdefaults\][[:space:]]*$/)
        }
        in_section && tolower($0) ~ /^[[:space:]]*verify_ap_req_nofail[[:space:]]*=/ {
            sub(/^[^=]*=[[:space:]]*/, "")
            sub(/[[:space:]#;].*$/, "")
            value=tolower($0)
        }
        END { if (value != "") print value }
    ' /etc/krb5.conf 2>/dev/null)"
fi

echo "================================================================="
echo "CVE-2023-3326 | Kerberos authentication validation audit"
echo "Mode: READ-ONLY (no package/configuration changes)"
echo "================================================================="

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    printf 'OS: %s\n' "${PRETTY_NAME:-Unknown}"
else
    echo "OS: Unknown"
fi

echo
echo "===== AFFECTED PACKAGE PRESENCE ====="
for pkg in libpam-krb5 sssd sssd-common sssd-krb5 sssd-krb5-common \
           sssd-ad sssd-ad-common sssd-ipa sssd-ldap sssd-proxy libpam-sss; do
    if is_installed "$pkg"; then
        version="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo unknown)"
        printf 'Installed: %-18s %s\n' "$pkg" "$version"
        AFFECTED_PACKAGES+=("$pkg")
    fi
done
if ((${#AFFECTED_PACKAGES[@]} == 0)); then
    echo "No CVE-tracked PAM Kerberos / SSSD packages detected."
fi

echo
echo "===== PAM INTEGRATION ====="
pam_krb5_active=false
pam_sss_active=false
if pam_stack_has_module 'pam_krb5\.so'; then
    pam_krb5_active=true
    echo "pam_krb5.so reference found under /etc/pam.d/"
else
    echo "No pam_krb5.so reference found under /etc/pam.d/"
fi

# Only the standard authentication/account/password/session stacks are used
# to decide whether pam_sss is wired into the normal PAM path. References in
# optional GDM smartcard-only profiles are reported separately as nonstandard.
if grep -Eqs '^[[:space:]]*[^#].*pam_sss\.so' \
    /etc/pam.d/common-auth /etc/pam.d/common-account \
    /etc/pam.d/common-password /etc/pam.d/common-session \
    /etc/pam.d/sshd /etc/pam.d/login /etc/pam.d/gdm-password \
    /etc/pam.d/sudo 2>/dev/null; then
    pam_sss_active=true
    echo "pam_sss.so reference found in a standard login/authentication stack."
else
    echo "No pam_sss.so reference found in the checked standard login stacks."
fi

echo
echo "===== SSSD CONFIGURATION / RUNTIME ====="
printf 'SSSD configuration with domains: %s\n' "$sssd_configured"
printf 'SSSD service or relevant socket active: %s\n' "$sssd_runtime_active"
printf 'SSSD Kerberos-capable provider configured (krb5/ad/ipa): %s\n' "$sssd_kerberos_provider"

echo
echo "===== KERBEROS VALIDATION SETTING ====="
if [[ "$verify_setting" == "true" || "$verify_setting" == "yes" ]]; then
    echo "verify_ap_req_nofail = true"
else
    echo "verify_ap_req_nofail is not explicitly true in [libdefaults] (value: ${verify_setting:-unset})"
fi

echo
echo "===== CVE-2023-3326 ASSESSMENT ====="

# Direct pam_krb5 path: only relevant when package and PAM integration exist.
if is_installed libpam-krb5 && "$pam_krb5_active"; then
    if [[ "$verify_setting" == "true" || "$verify_setting" == "yes" ]]; then
        pass "libpam-krb5 is integrated into PAM, but the documented Kerberos validation mitigation is enabled."
    else
        fail "libpam-krb5 is installed and referenced by PAM; Kerberos validation mitigation is not explicitly enabled."
    fi
elif is_installed libpam-krb5; then
    pass "libpam-krb5 is installed, but no pam_krb5.so PAM reference was found; active PAM use not identified."
else
    pass "libpam-krb5 is not installed."
fi

# SSSD path: installed packages alone do not establish an active Kerberos path.
if ((${#AFFECTED_PACKAGES[@]} > 0)) && \
   { is_installed sssd || is_installed sssd-common || is_installed sssd-krb5 || is_installed sssd-krb5-common || is_installed sssd-ad || is_installed sssd-ipa || is_installed sssd-ldap || is_installed sssd-proxy; }; then
    if [[ "$sssd_configured" == true && "$sssd_runtime_active" == true && "$sssd_kerberos_provider" == true ]]; then
        if [[ "$verify_setting" == "true" || "$verify_setting" == "yes" ]]; then
            pass "SSSD Kerberos-capable authentication is configured and active; documented validation mitigation is enabled."
        else
            fail "SSSD Kerberos-capable authentication is configured and active; documented validation mitigation is not explicitly enabled."
        fi
    elif [[ "$sssd_configured" == true && "$sssd_kerberos_provider" == false ]]; then
        pass "SSSD is configured, but no Kerberos-capable provider (krb5/ad/ipa) was identified."
    elif [[ "$sssd_configured" == true || "$sssd_runtime_active" == true ]]; then
        warn "SSSD is installed and configuration/runtime evidence exists, but active Kerberos use could not be confirmed."
    else
        pass "SSSD packages are installed, but no configured SSSD domain or active SSSD service/socket was identified."
    fi
fi

if [[ "$pam_sss_active" == true && "$sssd_configured" == false && "$sssd_runtime_active" == false ]]; then
    echo "[INFO] pam_sss.so is referenced by PAM, but SSSD has no configured domain and is not active."
fi

echo
echo "===================== FINAL RESULT ====================="
printf 'GREEN checks: %d | RED checks: %d | REVIEW checks: %d\n' "$GREEN" "$RED" "$REVIEW"
if ((RED > 0)); then
    echo "[RED] OVERALL: ACTION REQUIRED — an active Kerberos authentication path lacks the documented validation mitigation."
elif ((REVIEW > 0)); then
    echo "[REVIEW] OVERALL: MANUAL REVIEW REQUIRED — package/configuration evidence is inconclusive."
else
    echo "[GREEN] OVERALL: No active vulnerable Kerberos authentication path identified by these checks."
fi
echo "Note: Ubuntu tracks libpam-krb5 and SSSD as vulnerable with fix deferred; this script assesses local package/configuration/runtime exposure, not vendor patch status."
echo "========================================================="

# Self-removal
rm -f -- "$0"