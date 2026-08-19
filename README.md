# UAE Pass mobile app-to-app demo (Flutter / iOS)

Minimal reference implementation of the [UAE Pass app-to-app authentication
flow](https://docs.uaepass.ae/feature-guides/authentication/mobile-application/guide/api)
against the Fill Easy API, demonstrating the deep-link interception and rewrite
that UAE Pass requires from the SP mobile app (guide steps 4–8).

## Why this exists

On **staging**, the UAE Pass login page emits its app deep link with the
**production** scheme `uaepass://`. Opened in a plain browser, iOS routes that
to the production UAE Pass app. The documented fix is that the SP app loads the
login URL in an **embedded webview**, intercepts the deep link, and rewrites it:

- scheme `uaepass://` → `uaepassstg://` (staging only)
- `successurl` / `failureurl` → the SP app's own scheme, so control returns
  to the SP app after approval (required in production too)

All of that lives in `lib/main.dart` — see `_onNavigation` (interception) and
`_rewriteAndLaunch` (the rewrite). The rest is plumbing.

## Flow

```
Login button
  → POST /uaepass/request/auth {source: iOS}        (Fill Easy)
  → oAuthUrl loaded in embedded WebViewWidget       (doc step 2)
  → NavigationDelegate catches uaepass://…          (doc step 4)
  → save successurl/failureurl                      (doc step 5)
  → rewrite scheme + callbacks                      (doc step 6)
  → launchUrl → UAE Pass STAGING app opens          (doc step 7)
  → user approves → app opens fedemo:///resume_authn?url=…
  → saved successurl reloaded in the same webview   (doc step 8)
  → IdP issues code → Fill Easy /uaepass/callback exchanges it
  → webview reaches the `redirect` URL → closed
  → POST /uaepass/poll {token} → user profile shown
```

Every step is logged on-screen as it happens.

## Setup

1. `cp lib/config.example.dart lib/config.dart` and fill in the Fill Easy
   staging `clientId` / `clientSecret` (`config.dart` is gitignored).
2. On the test iPhone: install the
   [UAE Pass staging app](https://docs.uaepass.ae/resources/staging-apps),
   then trust "Dubai Smart Government" under Settings → General →
   VPN & Device Management. You need a
   [staging account](https://docs.uaepass.ae/quick-start-guide-uae-pass-staging-environment/create-uaepass-user)
   to approve logins.
3. `flutter pub get`, plug in the iPhone, `flutter run`.

## iOS configuration (already applied in `ios/Runner/Info.plist`)

- `LSApplicationQueriesSchemes`: `uaepassstg`, `uaepass` — lets the app probe
  which UAE Pass variant is installed and open it.
- `CFBundleURLTypes` scheme `fedemo` — the return path UAE Pass uses to hand
  control back after approval.
