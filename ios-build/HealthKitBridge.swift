import Capacitor
import HealthKit
import UIKit // needed for UIApplication.shared.open / openSettingsURLString (openHealthSettings/openHealthPermissions below)

// =============================================================================
// HealthKitBridge — iOS counterpart of the Android HealthBridge.kt Health
// Connect plugin, HEALTH SUBSET ONLY.
//
// The web app (app/index.html) feature-detects the native bridge with:
//     function HB() {
//       try { return (window.Capacitor && window.Capacitor.Plugins &&
//                      window.Capacitor.Plugins.HealthBridge) || null; }
//       catch { return null; }
//     }
// ...and then calls hb.available() / .requestHealthPermissions() /
// .openHealthSettings() / .openHealthPermissions() / .grantedPermissions() /
// .writeNutrition() / .readDay() IDENTICALLY regardless of which native
// plugin answers `window.Capacitor.Plugins.HealthBridge`. That is why this
// class's `jsName` below MUST be the literal string "HealthBridge" — same
// registered name as Android's `@CapacitorPlugin(name = "HealthBridge")` —
// even though the Swift type/file is named HealthKitBridge.
//
// Everything else HealthBridge.kt does (barcode scanning, speech-to-text,
// BLE scale, torch, notifications, Google sign-in, Firestore cloud sync,
// OTA content updates, saveToDownloads, httpGet/httpPost, side-key
// settings...) is explicitly OUT OF SCOPE here. iOS v1 deliberately uses the
// web-only fallbacks for all of that (see hcMiniVis()/HB() usage sites in
// app/index.html — every non-health call site is written to degrade
// gracefully when HB() returns something whose only methods are the 7 below).
//
// CAPACITOR VERSION TARGETED: this file targets Capacitor **8** — confirmed
// from ios-build/package.json ("@capacitor/ios": "^8.5.2"). Capacitor 7+
// local/first-party Swift plugins declare themselves via the CAPBridgedPlugin
// protocol (identifier / jsName / pluginMethods) instead of the older
// Objective-C `.m` bridging-header + CAP_PLUGIN() macro style. This mirrors
// how @capacitor-firebase/authentication (already a dependency here, per
// package.json) declares itself — that package's own Swift source could not
// be reached from this Windows machine to diff against directly, so this
// shape is written from the documented Capacitor 7/8 CAPBridgedPlugin
// protocol contract. THIS FILE HAS NOT BEEN COMPILED — there is no Mac/Xcode
// available in this environment. Please build once in Xcode and fix up any
// mismatch against the actual CAPBridgedPlugin.swift / CAPPlugin.swift in the
// resolved Capacitor SPM package if something here doesn't compile.
// =============================================================================

@objc(HealthKitBridge)
public class HealthKitBridge: CAPPlugin, CAPBridgedPlugin {

    // MARK: - CAPBridgedPlugin (Capacitor 7+/8 registration surface)

    public static let identifier = "HealthKitBridge"
    // MUST equal Android's @CapacitorPlugin(name = "HealthBridge") — this is
    // the key the web app looks up as window.Capacitor.Plugins.HealthBridge.
    public static let jsName = "HealthBridge"
    public static let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "available", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "requestHealthPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openHealthSettings", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "openHealthPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "grantedPermissions", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "writeNutrition", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "readDay", returnType: CAPPluginReturnPromise),
    ]

    // MARK: - HealthKit setup

    private let store = HKHealthStore()

    /// UserDefaults flag: "we have at least once asked HealthKit for
    /// authorization on this install". See grantedPermissions() below for
    /// why this is needed — HealthKit does not expose a reliable granted/
    /// denied answer for READ permissions the way Android's Health Connect
    /// PermissionController does.
    private static let didRequestKey = "fit.mrguru.scanlog.healthkit.didRequestAuth"

    /// Standard HKQuantityType lookup. Force-unwrap is safe here: every
    /// identifier used below (.stepCount, .activeEnergyBurned, etc.) is a
    /// long-standing Apple-defined identifier guaranteed to resolve on every
    /// iOS version that has HealthKit at all.
    private func qty(_ id: HKQuantityTypeIdentifier) -> HKQuantityType {
        return HKQuantityType.quantityType(forIdentifier: id)!
    }

    // Read permissions ≈ Android's healthPerms minus the write permission,
    // i.e. the "5 read + 1 write = 6" set HealthBridge.kt's comments refer
    // to (weight + BMR optional, steps/active-energy/total-energy/exercise
    // required). HealthKit has no single "total calories burned" record
    // type (see readDay's totalKcal comment below), so there is no direct
    // read-type analog for Android's TotalCaloriesBurnedRecord permission —
    // active + basal energy together are what compose it on iOS.
    private var readTypes: Set<HKObjectType> {
        return [
            qty(.stepCount),
            qty(.activeEnergyBurned),
            qty(.basalEnergyBurned),
            qty(.bodyMass),
            HKObjectType.workoutType(),
        ]
    }

    // Write permissions: exactly the 4 macros HealthBridge.kt's writeNutrition
    // puts into its NutritionRecord (energy/protein/carb/fat) — verified by
    // reading that method's body, no other macro (e.g. fiber, sugar) is
    // written there, so none is requested here either.
    private var writeTypes: Set<HKSampleType> {
        return [
            qty(.dietaryEnergyConsumed),
            qty(.dietaryProtein),
            qty(.dietaryCarbohydrates),
            qty(.dietaryFatTotal),
        ]
    }

    private func writeAuthorized() -> Bool {
        store.authorizationStatus(for: qty(.dietaryEnergyConsumed)) == .sharingAuthorized
    }

    // MARK: - available()  →  {healthConnect, appVersion}
    //
    // JS contract (app/index.html hcInit(), lines ~4243-4248):
    //   const a = await hb.available();
    //   if (a && a.appVersion) { NATIVE_VER = a.appVersion; renderVer(); }
    //   if (!a || !a.healthConnect) { show "not installed" state; return; }
    // Only `appVersion` and `healthConnect` are ever read — Android's extra
    // `status` and `nativeScanner` fields are NOT read anywhere in the JS,
    // and `nativeScanner` specifically concerns the barcode-scanner
    // subsystem, which is explicitly out of scope for this iOS task — so
    // both are intentionally omitted here rather than guessed at.
    @objc func available(_ call: CAPPluginCall) {
        var ret = JSObject()
        // NOTE (flagged intentionally): the JSON key is "healthConnect" —
        // literally Android's platform name — even though this is HealthKit.
        // Renaming it would break the shared JS contract above, since the
        // same index.html runs on both platforms unchanged. It simply means
        // "is on-device health data available" on whichever platform answers.
        ret["healthConnect"] = HKHealthStore.isHealthDataAvailable()
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            ret["appVersion"] = v
        }
        call.resolve(ret)
    }

    // MARK: - requestHealthPermissions()  →  {granted} or {granted:false, launched:true}
    //
    // JS contract (hcConnect(), lines ~4317-4330): races this call against an
    // 8s timeout, checks `r.granted`, and regardless of the outcome here it
    // always re-checks via grantedPermissions() afterwards — so this method
    // does not have to be the definitive source of truth, only a best-effort
    // reasonably-shaped response.
    @objc func requestHealthPermissions(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.reject("health_connect_unavailable")
            return
        }
        store.requestAuthorization(toShare: writeTypes, read: readTypes) { [weak self] success, error in
            guard let self = self else { return }
            UserDefaults.standard.set(true, forKey: Self.didRequestKey)
            if let error = error {
                call.reject("perm_error: " + error.localizedDescription)
                return
            }
            // `success` only means "the request completed without a system
            // error" — HealthKit deliberately does NOT tell an app whether
            // the user tapped Allow or Don't Allow for READ types (see the
            // long comment in grantedPermissions() below). The one type we
            // CAN verify precisely is the write (share) permission, so that
            // is what "granted" is keyed off here, matching what
            // grantedPermissions() will report a moment later anyway.
            let granted = success && self.writeAuthorized()
            var ret = JSObject()
            ret["granted"] = granted
            if !granted { ret["launched"] = true }
            call.resolve(ret)
        }
    }

    // MARK: - openHealthSettings() / openHealthPermissions()
    //
    // Android has two escalating deep links: openHealthSettings() opens the
    // Health Connect app's own home screen (broad escape hatch), and
    // openHealthPermissions() tries to jump straight to THIS app's
    // permission toggles inside Health Connect (specific). HealthKit has no
    // documented Intent-equivalent for either, so the two are mapped to the
    // two real iOS mechanisms that are closest in spirit — deliberately
    // NOT the same mechanism for both, to preserve the broad/specific split:
    //
    //   • openHealthSettings()  → `x-apple-health://`, the (undocumented but
    //     long-standing and widely relied-upon) URL scheme that opens the
    //     Health app itself. This is the direct analog of "open the Health
    //     Connect app's home screen" — broad, not app-specific.
    //
    //   • openHealthPermissions() → `UIApplication.openSettingsURLString`,
    //     i.e. this app's own page in iOS Settings. Since iOS 12, Settings ▸
    //     [App Name] shows a "Health" row for any app that has requested
    //     HealthKit access, and tapping it goes straight to that app's
    //     per-category read/write toggles. This is the Apple-documented,
    //     reliable route to a specific app's HealthKit permissions — closer
    //     in spirit to Android's "straight to THIS app's permission screen"
    //     than the Health app's own "Apps and Devices ▸ <app>" screen, which
    //     has no known deep-link URL at all.
    @objc func openHealthSettings(_ call: CAPPluginCall) {
        guard let url = URL(string: "x-apple-health://") else {
            call.reject("settings_error")
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                if ok { call.resolve() } else { call.reject("settings_error") }
            }
        }
    }

    @objc func openHealthPermissions(_ call: CAPPluginCall) {
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
            call.reject("settings_error")
            return
        }
        DispatchQueue.main.async {
            UIApplication.shared.open(url, options: [:]) { ok in
                if ok { call.resolve() } else { call.reject("settings_error") }
            }
        }
    }

    // MARK: - grantedPermissions()  →  {granted, weight, count}
    //
    // *** Biggest real behavioral difference from Android, flagged as
    // instructed rather than silently approximated: ***
    // Health Connect's PermissionController.getGrantedPermissions() gives an
    // exact, queryable granted/denied answer for every permission, including
    // READ permissions — that is what Android's `granted`/`weight`/`count`
    // are built from. HealthKit's `authorizationStatus(for:)` is documented
    // by Apple to be a RELIABLE signal only for WRITE (share) permissions.
    // For READ permissions it is explicitly privacy-obfuscated: an app must
    // not be able to distinguish "user denied read access" from "user has no
    // data of this type", so `authorizationStatus(for:)` on a read-only type
    // can report `.notDetermined` even after the user has responded, and
    // Apple's own docs warn against using it to gate UI. There is NO
    // HealthKit API that gives the Android-equivalent exact read-permission
    // count. What follows is the most honest approximation available:
    //   - `granted`: true only if a request was made at least once AND the
    //     one type that IS reliably queryable — the nutrition WRITE
    //     permission — is authorized. This under-reports "connected" for a
    //     user who granted only read access and denied write, but there is
    //     no false-positive risk, which matters more for hcSync()'s logic.
    //   - `weight`: bodyMass's authorizationStatus — same caveat as above;
    //     may read `.notDetermined` even when the user actually granted it.
    //   - `count`: how many of the 6 permission types have been "answered"
    //     (status != .notDetermined) rather than "granted" — Android's
    //     `count` literally counts grants; this iOS number is a weaker
    //     proxy and can overcount relative to Android's meaning. hcConnect()
    //     only uses `count` for a "3/6 approved…" progress string, so an
    //     approximate number here is a cosmetic mismatch, not a functional
    //     bug.
    @objc func grantedPermissions(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.reject("health_connect_unavailable")
            return
        }
        let requested = UserDefaults.standard.bool(forKey: Self.didRequestKey)
        let weightAuthorized = store.authorizationStatus(for: qty(.bodyMass)) == .sharingAuthorized
        let granted = requested && writeAuthorized()

        var answered = 0
        for t in readTypes where store.authorizationStatus(for: t) != .notDetermined { answered += 1 }
        if store.authorizationStatus(for: qty(.dietaryEnergyConsumed)) != .notDetermined { answered += 1 }

        var ret = JSObject()
        ret["granted"] = granted
        ret["weight"] = weightAuthorized
        ret["count"] = answered
        call.resolve(ret)
    }

    // MARK: - writeNutrition({name?, kcal, protein?, carb?, fat?, timeMs?})
    //
    // Mirrors HealthBridge.kt's writeNutrition exactly: one combined entry
    // per logged food, with energy + the 3 macros it writes (protein, total
    // carbohydrate, total fat — verified from that method's body; no fiber/
    // sugar/etc. is written there, so none is written here). HealthKit has
    // no single "nutrition record" type the way Health Connect's
    // NutritionRecord is one row with 4 fields — the closest equivalent is
    // an HKCorrelation of type .food bundling one HKQuantitySample per
    // macro, which is what Apple's own Health app itself uses for "meal"
    // entries so they show up as ONE row instead of 4 unlinked samples.
    @objc func writeNutrition(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.reject("health_connect_unavailable")
            return
        }
        guard let kcal = call.getDouble("kcal") else {
            call.reject("kcal required")
            return
        }
        let protein = call.getDouble("protein") ?? 0
        let carb = call.getDouble("carb") ?? 0
        let fat = call.getDouble("fat") ?? 0
        let name = call.getString("name")
        let timeMs = call.getDouble("timeMs") ?? (Date().timeIntervalSince1970 * 1000)

        let start = Date(timeIntervalSince1970: timeMs / 1000.0)
        let end = start.addingTimeInterval(60) // matches Android's fixed 60s duration

        let kcalUnit = HKUnit.kilocalorie()
        let gramUnit = HKUnit.gram()

        let energySample = HKQuantitySample(
            type: qty(.dietaryEnergyConsumed),
            quantity: HKQuantity(unit: kcalUnit, doubleValue: kcal),
            start: start, end: end)
        let proteinSample = HKQuantitySample(
            type: qty(.dietaryProtein),
            quantity: HKQuantity(unit: gramUnit, doubleValue: protein),
            start: start, end: end)
        let carbSample = HKQuantitySample(
            type: qty(.dietaryCarbohydrates),
            quantity: HKQuantity(unit: gramUnit, doubleValue: carb),
            start: start, end: end)
        let fatSample = HKQuantitySample(
            type: qty(.dietaryFatTotal),
            quantity: HKQuantity(unit: gramUnit, doubleValue: fat),
            start: start, end: end)

        var metadata: [String: Any] = [:]
        // HealthKit quantity samples have no free-text "name" field the way
        // Health Connect's NutritionRecord.name does — HKMetadataKeyFoodType
        // is the documented place a logged food's display name goes, and is
        // what makes it show up as e.g. "Banana" instead of just "Food" in
        // the Health app's nutrition list.
        if let name = name, !name.isEmpty {
            metadata[HKMetadataKeyFoodType] = name
        }

        guard let foodType = HKCorrelationType.correlationType(forIdentifier: .food) else {
            call.reject("write_error: food_correlation_type_unavailable")
            return
        }
        let correlation = HKCorrelation(
            type: foodType,
            start: start,
            end: end,
            objects: [energySample, proteinSample, carbSample, fatSample],
            metadata: metadata.isEmpty ? nil : metadata)

        store.save(correlation) { success, error in
            if success {
                call.resolve()
            } else {
                call.reject("write_error: " + (error?.localizedDescription ?? "unknown"))
            }
        }
    }

    // MARK: - readDay({startMs, endMs, weightDays}) → health-related subset
    //
    // JS contract — the ONLY fields hcSync() (app/index.html ~4358-4424)
    // actually reads off the result are:
    //   r.weightKg, r.stepsByOrigin, r.steps, r.sessionSteps, r.workoutKcal,
    //   r.sessions (array; only .length and each item's .startMs/.endMs are
    //   used — .kcal/.title/.type on each session are NOT read by JS today).
    // Everything else Android returns (activeKcal, totalKcal, weightAtMs,
    // stepsRaw, totalChunks, samsungBmrKcalDay, samsungRestRateKcalDay,
    // activityEstKcal) is NOT read anywhere in index.html's JS — confirmed by
    // grepping every one of those field names. They are Android/Samsung
    // diagnostic extras, not part of the real contract. This method still
    // populates the ones that have an honest, non-invented HealthKit
    // equivalent (activeKcal, totalKcal, weightAtMs, stepsRaw) for parity/
    // future use, clearly comments why, and DELIBERATELY OMITS the
    // Samsung-specific resting-rate-estimation heuristic
    // (samsungBmrKcalDay / samsungRestRateKcalDay / activityEstKcal /
    // totalChunks) — that heuristic exists on Android only because Samsung
    // Health's proprietary BMR isn't reliably exposed any other way; on iOS,
    // HealthKit's .basalEnergyBurned is a first-class, directly-queryable
    // type, so there is no equivalent need to reverse-engineer a resting
    // rate from the shape of a raw calorie stream. Inventing that heuristic
    // here anyway would be guessing at behavior the task said not to guess
    // at, for a field the JS never reads.
    @objc func readDay(_ call: CAPPluginCall) {
        guard HKHealthStore.isHealthDataAvailable() else {
            call.reject("health_connect_unavailable")
            return
        }
        guard let startMs = call.getDouble("startMs") else {
            call.reject("startMs required")
            return
        }
        let endMs = call.getDouble("endMs") ?? (Date().timeIntervalSince1970 * 1000)
        // Android clamps this to [1,29] days because Health Connect throws
        // without an extra history permission past 30 days back. HealthKit
        // has no equivalent short-history ceiling for a normal foreground
        // read query, so that artificial cap is intentionally NOT carried
        // over here — only the same default (14) is kept for parity.
        let weightDays = call.getDouble("weightDays") ?? 14

        let start = Date(timeIntervalSince1970: startMs / 1000.0)
        let end = Date(timeIntervalSince1970: endMs / 1000.0)
        let dayPredicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])

        // Each async branch below writes to its OWN local variable exactly
        // once; DispatchGroup.notify only runs after every leave(), so
        // reading these vars there is safe without extra locking. The two
        // exceptions (workout accumulation, step-origin accumulation) use an
        // NSLock because multiple loop iterations write into the SAME
        // accumulator concurrently.
        let group = DispatchGroup()

        var weightKg: Double?
        var weightAtMs: Double?
        var stepsTotal: Double?
        var activeKcal: Double?
        var basalKcal: Double?
        var sessions: JSArray = []
        var workoutKcal: Double?
        var sessionSteps: Double?
        var stepsByOrigin: [String: Double] = [:]
        var stepsRaw: Double = 0

        // ---- weight: most recent sample within weightDays of `end` ----
        group.enter()
        let weightStart = end.addingTimeInterval(-weightDays * 86400)
        let weightPredicate = HKQuery.predicateForSamples(withStart: weightStart, end: end, options: .strictEndDate)
        let weightSort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
        let weightQuery = HKSampleQuery(
            sampleType: qty(.bodyMass), predicate: weightPredicate, limit: 1, sortDescriptors: [weightSort]
        ) { _, samples, _ in
            if let s = (samples as? [HKQuantitySample])?.first {
                weightKg = s.quantity.doubleValue(for: .gramUnit(with: .kilo))
                weightAtMs = s.endDate.timeIntervalSince1970 * 1000
            }
            group.leave()
        }
        store.execute(weightQuery)

        // ---- steps: cumulative sum for [start,end] ----
        group.enter()
        let stepsQuery = HKStatisticsQuery(
            quantityType: qty(.stepCount), quantitySamplePredicate: dayPredicate, options: .cumulativeSum
        ) { _, stats, _ in
            if let sum = stats?.sumQuantity() { stepsTotal = sum.doubleValue(for: .count()) }
            group.leave()
        }
        store.execute(stepsQuery)

        // ---- active energy: cumulative sum for [start,end] ----
        // Kept for Android-return-shape parity even though hcSync() does not
        // read it today (see the field-audit note above the method).
        group.enter()
        let activeQuery = HKStatisticsQuery(
            quantityType: qty(.activeEnergyBurned), quantitySamplePredicate: dayPredicate, options: .cumulativeSum
        ) { _, stats, _ in
            if let sum = stats?.sumQuantity() { activeKcal = sum.doubleValue(for: .kilocalorie()) }
            group.leave()
        }
        store.execute(activeQuery)

        // ---- basal (resting) energy: cumulative sum for [start,end] ----
        // Android has no direct equivalent field name for this (its BMR
        // reads are a RATE from BasalMetabolicRateRecord, part of the
        // Samsung-specific heuristic this port intentionally does not carry
        // over — see the method-level comment). This is a period TOTAL, the
        // natural HealthKit shape, kept only so totalKcal below can be
        // computed honestly.
        group.enter()
        let basalQuery = HKStatisticsQuery(
            quantityType: qty(.basalEnergyBurned), quantitySamplePredicate: dayPredicate, options: .cumulativeSum
        ) { _, stats, _ in
            if let sum = stats?.sumQuantity() { basalKcal = sum.doubleValue(for: .kilocalorie()) }
            group.leave()
        }
        store.execute(basalQuery)

        // ---- workouts (≈ Android's ExerciseSessionRecord) ----
        group.enter()
        let workoutQuery = HKSampleQuery(
            sampleType: HKObjectType.workoutType(), predicate: dayPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil
        ) { [weak self] _, samples, _ in
            guard let self = self else { group.leave(); return }
            let workouts = (samples as? [HKWorkout]) ?? []
            if workouts.isEmpty {
                group.leave()
                return
            }
            let inner = DispatchGroup()
            let accLock = NSLock()
            // Declared as JSArray ([JSValue]), not [JSObject]: a concrete
            // [JSObject] array is a different type from JSArray even though
            // JSObject conforms to JSValue, so appending single JSObject
            // values into an already-JSArray-typed collection is what lets
            // this assign straight into `sessions` (also JSArray) below
            // without an explicit `as JSValue` cast per element.
            var builtSessions: JSArray = []
            var workoutSum = 0.0
            var sessionStepsSum = 0.0

            for w in workouts {
                inner.enter()
                var s = JSObject()
                s["title"] = self.workoutTitle(w)
                // Apple's own enum raw value — NOT numerically comparable to
                // Android's Health Connect exercise-type ints. JS does not
                // read this field today; kept only for rough shape parity.
                s["type"] = Int(w.workoutActivityType.rawValue)
                s["startMs"] = w.startDate.timeIntervalSince1970 * 1000
                s["endMs"] = w.endDate.timeIntervalSince1970 * 1000

                // totalEnergyBurned is deprecated (iOS 16+) in favor of
                // workout.statistics(for:), but remains functional on every
                // shipping iOS version and needs no #available branch — kept
                // for broad-compatibility simplicity since this file cannot
                // be compiled/tested here. Fine to modernize later in Xcode.
                if let kcal = w.totalEnergyBurned?.doubleValue(for: .kilocalorie()), kcal > 0 {
                    s["kcal"] = kcal
                    accLock.lock(); workoutSum += kcal; accLock.unlock()
                }

                // Steps that occurred during this workout's own window, so
                // hcSync()'s "freeSteps = allDaySteps - sessionSteps" doesn't
                // double-count a treadmill session's steps as free-walking
                // steps too (same reasoning as Android's sessionSteps).
                let sessionStepPredicate = HKQuery.predicateForSamples(withStart: w.startDate, end: w.endDate, options: [])
                let sessionStepQuery = HKStatisticsQuery(
                    quantityType: self.qty(.stepCount), quantitySamplePredicate: sessionStepPredicate, options: .cumulativeSum
                ) { _, stats, _ in
                    if let sum = stats?.sumQuantity() {
                        accLock.lock(); sessionStepsSum += sum.doubleValue(for: .count()); accLock.unlock()
                    }
                    accLock.lock(); builtSessions.append(s); accLock.unlock()
                    inner.leave()
                }
                self.store.execute(sessionStepQuery)
            }

            inner.notify(queue: .main) {
                sessions = builtSessions
                if workoutSum > 0 { workoutKcal = workoutSum }
                if sessionStepsSum > 0 { sessionSteps = sessionStepsSum }
                group.leave()
            }
        }
        store.execute(workoutQuery)

        // ---- steps grouped by writing source (≈ Android's stepsByOrigin) ----
        // HealthKit's per-sample HKSource.bundleIdentifier is the direct
        // analog of Android's metadata.dataOrigin.packageName — both are
        // "which app/watch wrote this sample", used by hcSync() to pick the
        // single largest source instead of trusting a deduped aggregate that
        // sometimes silently drops a writer.
        group.enter()
        let originQuery = HKSampleQuery(
            sampleType: qty(.stepCount), predicate: dayPredicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil
        ) { _, samples, _ in
            for case let sample as HKQuantitySample in samples ?? [] {
                let n = sample.quantity.doubleValue(for: .count())
                let bundleId = sample.sourceRevision.source.bundleIdentifier
                stepsByOrigin[bundleId, default: 0] += n
                stepsRaw += n
            }
            group.leave()
        }
        store.execute(originQuery)

        group.notify(queue: .main) {
            var ret = JSObject()
            if let w = weightKg { ret["weightKg"] = w }
            if let wa = weightAtMs { ret["weightAtMs"] = wa }
            if let s = stepsTotal { ret["steps"] = s }
            if let a = activeKcal { ret["activeKcal"] = a }
            // "totalKcal" on Android comes from a single Health Connect
            // record type (TotalCaloriesBurnedRecord). HealthKit has no
            // single equivalent type — active + basal energy together are
            // the honest HealthKit composition of "total calories burned",
            // so this is a COMPUTED value, not a directly-read one.
            if activeKcal != nil || basalKcal != nil {
                ret["totalKcal"] = (activeKcal ?? 0) + (basalKcal ?? 0)
            }
            ret["sessions"] = sessions
            if let wk = workoutKcal { ret["workoutKcal"] = wk }
            if let ss = sessionSteps { ret["sessionSteps"] = ss }
            var originObj = JSObject()
            for (k, v) in stepsByOrigin { originObj[k] = v }
            ret["stepsByOrigin"] = originObj
            ret["stepsRaw"] = stepsRaw
            call.resolve(ret)
        }
    }

    /// HealthKit workouts carry only a `workoutActivityType` enum, not a
    /// free-text title the way Android's ExerciseSessionRecord.title is
    /// (user/recording-app-supplied text on Android). This maps the common
    /// types to a readable label; JS does not read this field today (see
    /// the field-audit note on readDay), so this is parity/display-only.
    private func workoutTitle(_ w: HKWorkout) -> String {
        switch w.workoutActivityType {
        case .walking: return "Walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .swimming: return "Swimming"
        case .traditionalStrengthTraining, .functionalStrengthTraining: return "Strength Training"
        case .hiking: return "Hiking"
        case .yoga: return "Yoga"
        case .stairClimbing: return "Stair Climbing"
        case .elliptical: return "Elliptical"
        case .coreTraining: return "Core Training"
        case .highIntensityIntervalTraining: return "HIIT"
        default: return "Workout"
        }
    }
}
