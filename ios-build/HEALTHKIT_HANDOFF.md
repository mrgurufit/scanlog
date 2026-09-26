# HealthKit integration — finishing this in Xcode

Prepared on Windows with no Mac available, for the next cloud-Mac Xcode session.

## What's already done here
- `HealthKitBridge.swift` — the plugin (7 methods, jsName "HealthBridge").
- `Info.plist` — added `NSHealthShareUsageDescription` and
  `NSHealthUpdateUsageDescription` (Hebrew, matching the existing camera/mic/
  photo-library strings' tone).
- `App.entitlements` — HealthKit entitlement pair.

## What you need to do by hand in Xcode
1. **Add the Swift file to the target.** Drag `HealthKitBridge.swift` into the
   App project in Xcode (or File ▸ Add Files to "App"…), and confirm it's
   checked under the "App" target's **Build Phases ▸ Compile Sources**. If
   it's not in Compile Sources, it silently never runs — no build error.
2. **Turn on the HealthKit capability.** Target ▸ Signing & Capabilities ▸
   "+ Capability" ▸ HealthKit. Doing this through the Xcode UI (not just
   pointing at our hand-written `App.entitlements`) matters: Xcode's
   capability toggle auto-generates/merges its own entitlements file and may
   overwrite or ignore the one included here. After turning it on, open the
   resulting entitlements file and confirm it has
   `com.apple.developer.healthkit = true` and
   `com.apple.developer.healthkit.access = []` — if Xcode created a
   differently-named file, point the target's **Code Signing Entitlements**
   build setting at whichever file actually has these two keys (merge ours in
   if Xcode's version is missing them, don't just keep both files).
3. Info.plist is already done — nothing to add there.

Build and run on a real device (Simulator "supports" HealthKit calls but
always returns empty/denied data, so nothing meaningful can be verified
there). Once it builds, exercise `available()` first — if `healthConnect`
comes back `false` on a real iPhone, something above didn't take.
