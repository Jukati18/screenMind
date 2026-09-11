# Building & installing GeminiOCRScanner with no Mac

This repo layout lets a GitHub Actions **macOS runner** build the app for you.
You never touch Xcode. The output is an **unsigned** `.ipa`, which you then
sign and install onto your iPhone yourself using a free tool called
Sideloadly (runs on Windows, Mac, or Linux).

## Repo layout

```
GeminiOCRScanner-CI/
├── project.yml                     // XcodeGen spec — generates the .xcodeproj on the runner
├── Info.plist                      // Camera permission text, portrait-only
├── Sources/                        // Your 9 Swift files go here
│   └── *.swift
├── .github/workflows/build-ios.yml // The CI pipeline itself
└── README-CI.md                    // This file
```

## Step 1 — Set up your Gemini API key WITHOUT committing it

Never put a real API key directly in a file you're about to push to GitHub —
even a private repo can leak, and keys committed to git history are hard to
fully remove later. This project keeps the key out of git entirely:

1. Copy `Sources/Secrets.swift.example` to `Sources/Secrets.swift` (this new
   file is already listed in `.gitignore`, so git will never track it).
2. Open `Sources/Secrets.swift` and paste your real key from
   https://aistudio.google.com/app/apikey in place of `YOUR_GEMINI_API_KEY`.
3. This local copy is only useful if you ever build with Xcode directly. For
   the GitHub Actions build described below, add the key as a **repository
   secret** instead:
   - On your repo's GitHub page: **Settings → Secrets and variables →
     Actions → New repository secret**.
   - Name: `GEMINI_API_KEY`. Value: your real key. Click **Add secret**.
   - The workflow's "Inject Gemini API key" step writes this into a
     `Secrets.swift` file on the CI runner right before building — that file
     never gets committed back, and GitHub automatically masks the secret
     value in any log output.

Now it's safe to `git add .` and push — `Secrets.swift` itself will be
skipped by git, and only the harmless `Secrets.swift.example` template goes
up to GitHub.

## Step 2 — Put this in a GitHub repo

1. Create a free GitHub account if you don't have one: https://github.com/signup
2. Create a new repository (e.g. `gemini-ocr-scanner`), public or private, no
   need to initialize with a README.
3. On your computer, install Git if needed, then in this folder run:
   ```bash
   git init
   git add .
   git commit -m "Initial commit"
   git branch -M main
   git remote add origin https://github.com/YOUR_USERNAME/gemini-ocr-scanner.git
   git push -u origin main
   ```
   (No terminal experience? GitHub Desktop — https://desktop.github.com — does
   all of this with buttons instead of commands.)

## Step 3 — Run the build

Pushing to `main` triggers the workflow automatically. To check progress:
1. Go to your repo on github.com → the **Actions** tab.
2. Click the running workflow ("Build iOS IPA") to watch its progress.
3. It takes a few minutes. A green checkmark means it succeeded.
4. If it's red, click into the failed step to read the error — the most
   common issue is the Xcode version on the runner not matching what's
   expected; the "Show available Xcode versions" step in the log will show
   you what's actually installed if you need to adjust anything.

## Step 4 — Download the IPA

On the finished workflow run's summary page, scroll to **Artifacts** and
download `GeminiOCRScanner-ipa`. Unzip it — you'll get
`GeminiOCRScanner.ipa`.

## Step 5 — Install Sideloadly on your computer

Download from https://sideloadly.io (available for Windows and macOS).
(If you're on Linux, AltStore's community fork "SideStore" or a VM running
Windows are the usual workarounds — Sideloadly itself doesn't ship for Linux.)

## Step 6 — Sideload the IPA onto your iPhone

1. Connect your iPhone to your computer with a cable. Tap "Trust This
   Computer" on the phone if asked.
2. Open Sideloadly. It should detect your iPhone.
3. Drag `GeminiOCRScanner.ipa` into Sideloadly's window.
4. Enter your Apple ID email. If your Apple ID has two-factor authentication
   on (it almost certainly does), generate an **app-specific password** at
   https://appleid.apple.com → Sign-In and Security → App-Specific Passwords,
   and use that instead of your normal password.
5. Click **Start**. Sideloadly signs the app with a free personal-team
   certificate tied to your Apple ID and installs it.

> Running into a "Local Anisette" error loop or a fatal IPC error during
> this step? See [Troubleshooting: Sideloadly Local Anisette
> errors](#troubleshooting-sideloadly-local-anisette-errors) below.

## Step 7 — Trust the developer certificate on your iPhone

The first launch will fail with "Untrusted Developer." Go to iPhone
**Settings → General → VPN & Device Management**, tap your Apple ID entry,
tap **Trust**. Now open the app from the Home Screen.

> App still won't launch after this? See [Troubleshooting: app won't launch
> — iOS Developer Mode](#troubleshooting-app-wont-launch--ios-developer-mode)
> below.

## About the 7-day limit

Apps signed with a **free** Apple ID expire after 7 days and stop launching.
To renew: reconnect your phone, open Sideloadly, and hit Start again with the
same IPA (no need to rebuild). Sideloadly also has an "Auto Sign IPA over
Wi-Fi" background feature that can re-sign it automatically before it expires
if your phone and computer are on the same network — check the app's
settings if you want that instead of doing it manually each week.

## Updating the app after code changes

Edit the Swift files, commit, and push again — the workflow re-runs and
produces a fresh IPA automatically. Download it and repeat Steps 4–7.

---

## Troubleshooting: quick reference

| Symptom | Likely cause | Fix |
|---|---|---|
| Build fails: "future Xcode project file format" | XcodeGen output newer than runner's Xcode | Already patched in `build-ios.yml` — check the patch step ran |
| App installs but every answer says "Gemini API error" | `GEMINI_API_KEY` secret missing or wrong | Re-check Step 1 above, re-run the workflow |
| "Untrusted Developer" won't go away | Trust step done on wrong entry, or app reinstalled | Redo Step 7 above exactly, restart the phone if it persists |
| App stops opening after about a week | Free Apple ID 7-day signing expiry | See "About the 7-day limit" above — re-sign with Sideloadly |
| Sideloadly can't find my iPhone | Cable/trust issue, or Wi-Fi sync interfering | Reconnect via USB, tap Trust again, restart Sideloadly |
| `git status` shows `Sources/Secrets.swift` as untracked | `.gitignore` isn't matching it | Confirm the file is literally named `Secrets.swift` and sits directly in `Sources/` |
| Sideloadly stuck in a "Local Anisette" error loop | Local DLL setup on Windows failing | See detailed section below |
| App installs but won't launch, no clear error | iOS Developer Mode not enabled | See detailed section below |

## Troubleshooting: Sideloadly Local Anisette errors

**Symptoms**, in this order:
1. `Local Anisette problem: ... open C:\Program Files\Sideloadly\an\iTunesCore.dll: The system cannot find the file specified. Do you want to download it?`
2. You click **Yes**, it "installs," then immediately shows the same dialog
   again, now mentioning `Redist install failed` and listing MSVC redist /
   iTunes troubleshooting steps.
3. Clicking **Yes** again produces a **Sideloadly Warning** about needing
   administrator permission, mentioning `remove ...\an\icudt55.dll: Access
   is denied.`
4. Clicking **OK** and granting admin access ends in a **Fatal Error**:
   `IPC fail: Local Anisette should be updated: open ...\an\iTunesCore.dll:
   The system cannot find the file specified.`

**What's actually happening:** Sideloadly's local Anisette setup needs to
write several DLLs (borrowed from iTunes/iCloud) into its own `an\`
subfolder. Something is preventing that write — most commonly a locked
file, a missing/incompatible iTunes install, missing VC++ runtimes, or a
permissions issue on `Program Files`. The dialog loop just keeps retrying
the same failing step.

**Fix, in order — stop as soon as it works:**

1. **Close Sideloadly completely** (check it's not lingering in Task
   Manager) before touching any files.
2. **Fully remove Sideloadly.** It's often a portable app, so it may not
   appear in Windows Settings → Apps at all — that's normal. Just delete
   its folder (e.g. `C:\Program Files\Sideloadly`) by hand.
3. **Reinstall iTunes and iCloud from Apple's website**, not the Microsoft
   Store. If you had the Store versions, fully uninstall them first (a tool
   like Revo Uninstaller helps catch leftovers) before installing the
   `.exe` versions.
4. **Install both VC++ Redistributables** — Microsoft Visual C++ 2010 SP1
   (x64) *and* 2013 (x64). Both installers are named `vcredist_x64.exe` but
   are different files for different runtime versions; you need both. If
   Windows says "Repair" instead of "Install," that just means it's already
   present and healthy — click through it, no problem.
5. **Reinstall Sideloadly fresh, but don't open it yet.**
6. **Add Sideloadly's `an` folder to your system PATH:**
   - Open **Edit the system environment variables** → **Environment
     Variables**.
   - Under **System variables**, scroll to find **Path**, select it, click
     **Edit**.
   - Click **New**, add the full path to the `an` subfolder, e.g.
     `C:\Program Files\Sideloadly\an` (confirm your actual install path in
     File Explorer first).
   - Select the new entry, click **Move Up** until it's at the top of the
     list, then **OK** through every open dialog.
   - **Restart your PC** — this is required for PATH changes to apply.
7. Launch Sideloadly and try again.

If you hit an **"Error opening file for writing"** dialog *during*
reinstall (e.g. on `_asyncio.pyd`), that's a separate file-lock/permission
issue, not a sign anything above was wrong:
- Click **Abort**, don't just Retry repeatedly.
- Check Task Manager for a leftover `Sideloadly` process (search "sideloadly",
  not generic terms — "asy" will match unrelated Windows system processes
  like "Sink to receive asynchronous callbacks," which you can ignore).
- Close any File Explorer window open in that folder.
- Run the installer **as Administrator**.
- Temporarily disable antivirus real-time protection, then re-run the
  installer from scratch.
- If it still fails on the same file, manually delete the leftover
  `C:\Program Files\Sideloadly` folder before reinstalling.

**Last resort:** if nothing above works, switch to Sideloadly's **Remote
Anisette** option (in its settings) instead of Local Anisette — it skips
the local DLL setup entirely and uses a hosted anisette server, at the
cost of needing an internet connection every time you sign.

## Troubleshooting: app won't launch — iOS Developer Mode

**Symptom:** You've trusted the developer certificate (Step 7 above), but
tapping the app icon still refuses to launch — sometimes with no error,
sometimes with a dialog about the app being unavailable.

**What's actually happening:** This isn't a build or code problem — it's a
one-time iPhone setting that every sideloaded app hits. Since iOS 16, Apple
requires **Developer Mode** to be manually turned on before any app signed
outside the App Store (via Sideloadly, Xcode, etc.) is allowed to run. Your
app installed correctly — the OS is just refusing to launch it until you
flip this switch.

**Fix it on your iPhone:**

1. Tap **OK** to dismiss the dialog.
2. Go to **Settings → Privacy & Security**.
3. Scroll all the way down — you'll see a **Developer Mode** toggle near the
   bottom (it only appears after you've tried to install a sideloaded app
   once, which you've now done).
4. Turn it **on**.
5. The iPhone will prompt you to **Restart**. Do it.
6. After restart, unlock the phone — a popup will ask you to confirm
   **"Turn On Developer Mode?"**. Tap **Turn On**, then enter your passcode.
7. Open `GeminiOCRScanner` from the Home Screen again — it should launch
   normally now.

This is a one-time setting per device — you won't need to repeat it for
future rebuilds or re-signs, only the initial sideload.