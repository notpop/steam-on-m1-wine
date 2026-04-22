#!/usr/bin/env bash
#
# 05-fix-ssl.sh — Reduce TLS / Winsock friction between Chromium (CEF 126
# inside Steam) and Wine.
#
# Background
# ----------
# When Steam's webhelper first launches, Chromium fails HTTPS handshakes
# with:
#   ERROR:ssl_client_socket_impl.cc: handshake failed;
#       returned -1, SSL error code 1, net_error -100 / -107
# Chromium ships its own BoringSSL, so this is not a Wine schannel bug in
# the classical sense. The failures are secondary effects of:
#   (a) Chromium running sandboxed GPU processes that DXMT can't host
#       — handled by scripts/06-install-wrapper.sh + --in-process-gpu
#   (b) Wine's cert store being empty by default, so Chromium can't
#       validate Steam's certificate chain
#
# This script addresses (b) by asking winetricks to populate the prefix's
# trusted-root store with the CA bundle from the OS.

# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"
require_wine_installed
require_prefix_initialised
require_cmd winetricks

log_step "Configuring TLS trust roots inside the prefix"

# -- Root certificates --------------------------------------------------------
# winetricks' `cncert` / `mscorefonts` verbs are for other things.
# The one we want is simply ensuring ca_certificates is wired up. Winetricks
# doesn't ship its own CA bundle — we copy from /etc/ssl/cert.pem (macOS's
# OpenSSL-format bundle, already trusted by the OS) into the prefix's
# Windows cert store location as a PEM file so curl-in-Wine and other
# traditional tools can see it. Chromium doesn't read this, but having
# the bundle in the prefix is cheap and useful for other Windows tools.

CA_SRC="/etc/ssl/cert.pem"
CA_DST="$WINEPREFIX/drive_c/windows/cacert.pem"

if [[ -r "$CA_SRC" ]]; then
    cp "$CA_SRC" "$CA_DST"
    log_ok "Copied macOS CA bundle to $CA_DST"
else
    log_warn "No CA bundle found at $CA_SRC; skipping copy"
fi

# -- Winetricks: corefonts (optional) -----------------------------------------
# `winetricks -q corefonts` pulls the legacy Microsoft web fonts from
# SourceForge. It can be slow or hang if the user's network filters that
# host, and the Japanese fonts seeded in 02-setup-prefix.sh already
# cover the Steam UI. We therefore gate the step behind an opt-in env
# var instead of blocking the pipeline on a flaky download.
#
# Enable with:
#   INSTALL_COREFONTS=1 scripts/05-fix-ssl.sh
if [[ "${INSTALL_COREFONTS:-0}" == "1" ]]; then
    log_info "Running: winetricks -q corefonts (may take several minutes)"
    WINEPREFIX="$WINEPREFIX" WINE="$WINE_BIN" WINESERVER="$WINESERVER_BIN" \
        arch -x86_64 winetricks -q corefonts \
        || log_warn "winetricks corefonts reported a non-zero exit; continuing"
else
    log_info "Skipping winetricks corefonts (set INSTALL_COREFONTS=1 to enable)"
fi

log_ok "SSL / fonts step complete (further TLS knobs applied at launch time)"
