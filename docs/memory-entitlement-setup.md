# Getting past the "Memory Entitlement" Setup Check

If AetherPS4-iOS's Setup Check screen fails the "Memory Entitlement" row, this
is what's going on and how to fix it for your own install.

## Why this happens

AetherPS4-iOS's `.entitlements` file requests two memory-pressure
entitlements from Apple: `increased-memory-limit` and
`extended-virtual-addressing` (either one is enough -- the app accepts
whichever made it into your install's actual signature). But **declaring an
entitlement in `.entitlements` is not enough on its own**: Apple only
actually grants an entitlement to a sideloaded app if the App ID's
corresponding capability is enabled on the Apple Developer Portal first.
Plain sideloading doesn't do this automatically.

Crucially, this capability is registered per **Apple Developer team** (i.e.
per Apple ID), not globally per bundle identifier. That means there is no
one-time fix a maintainer can apply that helps everyone -- **every person
sideloading this app needs to enable the capability once for their own
Apple ID**. This is a limitation of Apple's own provisioning system, not
something specific to this project. Which of the two options below is less
work overall depends on whether you're only ever going to run this one app,
or expect to sideload other memory-hungry apps (other emulators, etc.) in
the future too.

## Option A (recommended): do it once, forever, via LiveContainer

[LiveContainer](https://github.com/LiveContainer/LiveContainer) runs other
apps' code as "guests" inside its own single installed app. Per its own
docs, a guest app does not get its own entitlements at runtime -- it runs
under **LiveContainer's own App ID and signature instead**. Practically,
that means: enable the memory capability on LiveContainer's own App ID once,
and *every* memory-hungry app you ever load inside it afterward -- this one
included -- inherits it automatically, with no further setup. This is not
speculative -- comparable emulators (DolphiniOS, MelonX, Amethyst) already
use exactly this pattern in production.

LiveContainer also explicitly supports StikDebug as an external JIT enabler
(the same JIT mechanism this app already uses), including specifically for
iOS 26+, so there's no conflict there.

1. Install LiveContainer via SideStore, same as any other app.
2. In LiveContainer's settings, under JIT, pick **StikDebug** as the JIT
   enabler.
3. Enable the memory capability for LiveContainer's own App ID
   (`com.kdt.livecontainer.<yourteamid>` -- check LiveContainer's own app
   details for the exact value) using **either**:
   - [GetMoreRam](https://github.com/hugeBlack/GetMoreRam) run as a guest
     app inside LiveContainer itself (the common community path for this --
     see [this walkthrough](https://docvault.celloserenity.dev/walkthroughs/LiveContainer-iOS-26-JIT/getmoreram)).
     As of this writing GetMoreRam has a real sign-in bug (see "Why not
     GetMoreRam?" below) that may still block this regardless of which App
     ID it's targeting -- if you hit that, use the next option instead.
   - Or [`runtime/scripts/enable-memory-entitlement.sh`](../runtime/scripts/enable-memory-entitlement.sh)
     (see Option B below for how to run it), entering LiveContainer's bundle
     ID when it asks instead of AetherPS4-iOS's.
4. **You do NOT sideload AetherPS4-iOS through SideStore at all in this
   option.** Download AetherPS4-iOS's `.ipa` (e.g. from this repo's
   [`ios-latest` release](https://github.com/st4rwhx/iPS4/releases/tag/ios-latest))
   onto your device, open LiveContainer, tap the **+** button in the top
   right, and pick that `.ipa` file. It gets imported and runs as a guest
   app entirely inside LiveContainer -- it never appears as its own
   separate home-screen app or gets its own SideStore entry. Launch it from
   inside LiveContainer, with "Launch with JIT" enabled for it.

**Known unknown:** this app is more involved than a typical LiveContainer
guest -- it ships its own `Frameworks/BreakpointJIT.framework`, does its own
package-extraction and heavy file access, and is a full SwiftUI app rather
than a thin emulator core. LiveContainer's guest sandbox stays intact around
loaded apps, and this specific combination hasn't been verified working. If
you hit issues running it as a LiveContainer guest specifically (as opposed
to the entitlement step itself), fall back to Option B.

## Option B: fix it for this one app directly, no LiveContainer

If you'd rather not add LiveContainer to your setup, or Option A doesn't
work for this app specifically, you can enable the same capability directly
on AetherPS4-iOS's own App ID instead -- this only helps this one app, and
you'd repeat it for any other memory-hungry app you sideload in the future.

`increased-memory-limit` itself has no documented, scriptable way to enable
it -- the only known route is Xcode's own GUI (a real Mac). But
`extended-virtual-addressing` *is* a fully documented, API-reachable
capability, and this app already accepts it as an equally valid alternative.
[`runtime/scripts/enable-memory-entitlement.sh`](../runtime/scripts/enable-memory-entitlement.sh)
enables it for your own Apple ID using `fastlane` -- a mature, widely-used
tool talking to Apple's real Developer Portal API, rather than an
unmaintained reimplementation of Apple's private auth protocol (see "Why not
GetMoreRam?" below for why that distinction matters). No Mac, no Xcode, no
paid Apple Developer Program membership -- and the two-factor approval it
prompts you for is the one part only your own device can complete; that's a
limit of Apple's own two-factor system, not of this script, and nothing
(this script, GetMoreRam, or anyone else) can automate around it. This repo
is set up so the *environment* for running it costs you nothing to set up:

0. **Open a Codespace on this repo** -- github.com/st4rwhx/iPS4, green
   "Code" button -> Codespaces tab -> "Create codespace on main". This opens
   a full terminal in your browser (works from a phone, though a larger
   screen makes typing easier) with `fastlane` already installed for you --
   nothing to configure. (Delete the Codespace when you're done -- Settings
   -> Codespaces on GitHub's site, or just let it auto-stop; you won't need
   it again unless your session expires.)

   If you'd rather use your own Linux/WSL/macOS machine instead, that works
   identically (the script installs `fastlane` itself if it's missing).

1. **Run the script:**
   ```sh
   ./runtime/scripts/enable-memory-entitlement.sh
   ```
   It walks you through everything in one go: your Apple ID email, which App
   ID to target (defaults to this app's own `com.aether.ps4ios`, or enter
   LiveContainer's bundle ID instead if you're using Option A), then your
   Apple ID password and a 2FA code if prompted -- all inline, no separate
   steps to remember.

2. **Reinstall (not "Refresh") the app whose bundle ID you entered, from
   SideStore.** SideStore will regenerate its provisioning profile, which
   now includes the capability you just enabled -- so the entitlement
   should be present in the resigned app's real signature this time.

## Why not GetMoreRam?

[GetMoreRam](https://github.com/hugeBlack/GetMoreRam) automates roughly this
same idea from an on-device app instead of a terminal, which is more
convenient when it works (and is the standard tool for the LiveContainer
route in Option A). As of this writing it has a real, reproducible sign-in
bug (an unprotected property-list parse of Apple's own `gsa.apple.com`
authentication response, in its `StosSign` dependency, confirmed present in
both the fork it uses and the canonical upstream) that throws
`NSCocoaErrorDomain` code 3840 ("The data couldn't be read...") during
sign-in, independent of network/VPN. If that gets fixed upstream in the
future, GetMoreRam is likely the more convenient path for most people;
until then, the `fastlane` route above works around it entirely by talking
to Apple's Developer Portal API directly.
