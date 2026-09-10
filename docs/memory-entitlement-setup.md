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
Apple ID**, the same way every SideStore/AltStore user already re-signs the
app with their own account. This is a limitation of Apple's own
provisioning system, not something specific to this project.

## The fix: enable it yourself, no Mac required

`increased-memory-limit` itself has no documented, scriptable way to enable
it -- the only known route is Xcode's own GUI (a real Mac). But
`extended-virtual-addressing` *is* a fully documented, API-reachable
capability, and this app already accepts it as an equally valid alternative.
You can enable it for your own Apple ID with `fastlane`, which is a plain
Ruby gem -- it runs on Linux, WSL, a GitHub Codespace, or macOS. No Mac, no
Xcode, no paid Apple Developer Program membership required.

1. **Install fastlane** (anywhere with Ruby):
   ```sh
   gem install fastlane
   ```

2. **Authenticate once, interactively** (this is the only step that needs
   your own two-factor approval -- do it on whichever device gets your 2FA
   prompts):
   ```sh
   fastlane spaceauth -u your@appleid.com
   ```
   Approve the prompt on your device. This prints a session string to your
   terminal -- you won't need to save it anywhere; the next command runs
   right after in the same session.

3. **Find your app's exact bundle ID.** Open SideStore, tap AetherPS4-iOS in
   your app list, and check its App ID -- it's usually `com.aether.ps4ios`
   exactly as built, but SideStore occasionally appends a suffix for
   free-account App ID limits. Use whatever it actually shows.

4. **Enable the capability:**
   ```sh
   fastlane produce enable_services \
     -a com.aether.ps4ios \
     --extended-virtual-address-space
   ```
   (replace `com.aether.ps4ios` with your app's actual bundle ID from step 3
   if it differs)

5. **Reinstall (not "Refresh") AetherPS4-iOS from SideStore.** SideStore
   will regenerate the provisioning profile for your App ID, which now
   includes the capability you just enabled -- so the entitlement should be
   present in the resigned app's real signature this time.

## Why not GetMoreRam?

[GetMoreRam](https://github.com/hugeBlack/GetMoreRam) automates roughly this
same idea from an on-device app instead of a terminal, which is more
convenient when it works. As of this writing it has a real, reproducible
sign-in bug (an unprotected property-list parse of Apple's own
`gsa.apple.com` authentication response, in its `StosSign` dependency,
confirmed present in both the fork it uses and the canonical upstream) that
throws `NSCocoaErrorDomain` code 3840 ("The data couldn't be read...")
during sign-in, independent of network/VPN. If that gets fixed upstream in
the future, GetMoreRam is likely the more convenient path for most people;
until then, the `fastlane` route above works around it entirely by talking
to Apple's Developer Portal API directly.
