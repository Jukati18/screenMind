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

## Step 7 — Trust the developer certificate on your iPhone

The first launch will fail with "Untrusted Developer." Go to iPhone
**Settings → General → VPN & Device Management**, tap your Apple ID entry,
tap **Trust**. Now open the app from the Home Screen.

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
