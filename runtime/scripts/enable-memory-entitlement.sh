#!/usr/bin/env bash
# Enables the "Extended Virtual Addressing" capability on an App ID via Apple's real
# Developer Portal API, so a sideloaded install of this app (or of LiveContainer, if you run
# guest apps through it -- see docs/memory-entitlement-setup.md) can actually get the
# extended-virtual-addressing entitlement it already requests in its own .entitlements file.
#
# Why this exists instead of using GetMoreRam: GetMoreRam (github.com/hugeBlack/GetMoreRam)
# does the same job from an on-device app, which is more convenient when it works, but as of
# this writing it has a real, reproducible sign-in bug in its StosSign dependency (an
# unprotected property-list parse of Apple's own gsa.apple.com auth response -- confirmed
# present in both the fork it uses and the canonical upstream, deterministic, independent of
# network/VPN). Rather than depend on that unmaintained, unfixed reimplementation of Apple's
# private auth protocol, this script drives the exact same underlying Apple API through
# `fastlane`/`produce` -- a mature, widely-used, actively-maintained tool millions of CI
# pipelines already rely on for this.
#
# Why extended-virtual-addressing and not increased-memory-limit: the latter has no
# documented, API-reachable way to enable it at all (confirmed by reading fastlane/spaceship's
# own BundleIdCapability::Type source -- it simply isn't in Apple's public capability list;
# the only known route is Xcode's own GUI, which needs a real Mac). This app's own runtime
# check (SetupCheckView.swift) already accepts either entitlement, so enabling this one alone
# is a complete fix.
#
# Requires only Ruby -- works from a GitHub Codespace on this repo (nothing to install, see
# .devcontainer/devcontainer.json), a Linux/WSL machine, or macOS. No Mac, no Xcode, no paid
# Apple Developer Program membership. You will be prompted for your Apple ID password and (if
# your account has it enabled, which it should) a two-factor code -- this is the one part of
# the whole process that genuinely cannot be automated by anyone, since Apple's own two-factor
# flow requires a live human to approve it.

set -euo pipefail

if ! command -v fastlane >/dev/null 2>&1; then
  echo "==> fastlane not found, installing (gem install fastlane)..."
  gem install fastlane --no-document
fi

read -rp "Apple ID email: " APPLE_ID
if [[ -z "$APPLE_ID" ]]; then
  echo "error: Apple ID email is required" >&2
  exit 1
fi

echo ""
echo "Which App ID should get the capability?"
echo "  1) AetherPS4-iOS directly (com.aether.ps4ios) -- fixes only this app"
echo "  2) LiveContainer (you'll need its exact bundle ID, e.g. com.kdt.livecontainer.<TEAMID> --"
echo "     check LiveContainer's own app details) -- fixes every app you load through it,"
echo "     forever, not just this one. See docs/memory-entitlement-setup.md Option A."
read -rp "Enter the exact bundle ID to use [com.aether.ps4ios]: " BUNDLE_ID
BUNDLE_ID="${BUNDLE_ID:-com.aether.ps4ios}"

echo ""
echo "==> Enabling Extended Virtual Address Space for $BUNDLE_ID"
echo "    (you'll be prompted for your Apple ID password, then a 2FA code if applicable)"
echo ""

fastlane produce enable_services \
  -u "$APPLE_ID" \
  -a "$BUNDLE_ID" \
  --extended-virtual-address-space

echo ""
echo "==> Done. Reinstall (not \"Refresh\") the app whose bundle ID this was ($BUNDLE_ID) from"
echo "    SideStore so it picks up the newly-enabled capability in its resigned provisioning"
echo "    profile."
