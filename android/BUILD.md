# First build — step by step

> This project is a standard Android Studio Gradle project with a pinned wrapper
> (Gradle 8.7, AGP 8.5.2, Kotlin 1.9.24). Nothing else is vendored — the SDK and a
> JDK 17 come from Android Studio.

## 0. Prerequisites (once)

1. Download **Android Studio** (latest) from https://developer.android.com/studio and install it.
   It bundles a JDK 17 (JBR) and, via the Setup Wizard, the **Android SDK**.
2. On first launch, let the Setup Wizard install: **Android SDK Platform API 34** and the latest
   **Android SDK Build-Tools** + **Platform-Tools** (adb).

## 1. Open the project

3. Android Studio → **File ▸ Open…** → select `C:\_CAR_APP\fap_modern` → OK.
4. Studio auto-writes `local.properties` (pointing at your SDK) and starts a **Gradle sync**.
   First sync downloads Gradle 8.7 + AndroidX/Material artifacts (~a few hundred MB, needs internet).
   Wait for **"Sync finished / BUILD SUCCESSFUL"** in the Build panel.
5. Confirm the Gradle JDK is 17: **Settings ▸ Build, Execution, Deployment ▸ Build Tools ▸ Gradle**
   → *Gradle JDK* = `jbr-17` (bundled). (AGP 8.5 requires JDK 17.)

## 2. Run on a phone

6. On the phone: **Settings ▸ About ▸ tap Build number ×7** → Developer options → enable **USB debugging**.
7. Plug in over USB, accept the RSA fingerprint prompt.
8. Pick the device in the toolbar dropdown, press **Run ▶** (Shift+F10).
   Studio builds a debug APK, installs and launches **FAP Live**.

## 3. Command-line build (optional, after step 4 has created local.properties)

From `C:\_CAR_APP\fap_modern`:

```bat
gradlew.bat assembleDebug
```

- Output APK: `app\build\outputs\apk\debug\app-debug.apk`
- Install it: `adb install -r app\build\outputs\apk\debug\app-debug.apk`

If a CLI build ever reports **"SDK location not found"**, create `local.properties` manually:

```properties
sdk.dir=C\:\\Users\\Danil\\AppData\\Local\\Android\\Sdk
```

## Common first-build snags

| Symptom | Fix |
|---|---|
| "Failed to find Platform SDK with path: platforms;android-34" | SDK Manager → install **Android 14 (API 34)**, re-sync |
| "Build-Tools revision … not found" | SDK Manager → install latest **Build-Tools**, re-sync |
| "Gradle JDK … must be Java 17" | Settings → Gradle → Gradle JDK = `jbr-17` |
| Sync stuck downloading | first sync needs internet; check proxy/firewall |
| App installs but list stays "--" | expected until an ELM327 is connected and ignition is on |

## First run in the app

1. `CFG` → choose **Bluetooth** (pick your paired ELM327) or **WiFi** (`192.168.0.10:35000`).
   Grant the Bluetooth permission when Android 12+ asks.
2. `Connect`, ignition on.
3. Scroll the list; tap any numeric parameter to open its live zoomable graph.
