# Somar SDK for Apple platforms

Send your app's events, sessions, errors, and feature-flag reads to your Somar workspace — where they become live analytics pages, AI insights, and automations.

## Install

Add the package in Xcode (File → Add Package Dependencies) or in `Package.swift`:

```swift
.package(url: "https://github.com/somar/somar-sdk-swift", from: "0.1.0")
```

## Use

```swift
import SomarSDK

Somar.initialize(apiKey: "somar_pk_…")           // at app launch

Somar.capture("signup_completed", ["plan": "pro"])
Somar.identify("user-42", ["name": "Ada"])
Somar.screen("Onboarding")
Somar.group("company", "acme-inc")
Somar.captureError(error)

if Somar.isEnabled("new-onboarding") { /* … */ }

Somar.reset()                                     // on logout
```

Find your project key in Somar → Settings → Product SDK. The key is a public, ingestion-scoped credential — safe to ship in client code.

Events batch (20 events / 10 s), persist to disk while offline, and flush when the app backgrounds. Sessions rotate after 30 minutes of inactivity.

## Develop

```bash
swift build && swift test
```
