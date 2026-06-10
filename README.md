# [glacierApp](http://www.theglacierapp.com)

[Glacier](http://www.theglacierapp.com) is a privacy and security app for iOS.

It bundles several layers of protection in a single client:

- **WireGuard VPN** with on-demand activation and trusted-network rules
- **DNS-over-TLS** (encrypted DNS) with a built-in DNS health check
- **Non-attributable voice** via Twilio
- A Home Screen / Lock Screen **widget** for one-tap VPN and DNS toggling
- A **Security Center** that surfaces device security issues and tracker-blocking analytics

Glacier is published under a **Source Available** license — see [LICENSE](LICENSE)
for the full terms and the [License](#license) section at the bottom of this
README for attribution of third-party components.

## Requirements

| Tool | Version |
| --- | --- |
| Xcode | 16.0 or later |
| iOS deployment target | 18.0 |
| Swift | 5.0 |
| Ruby | 3.0+ (for CocoaPods) |
| CocoaPods | 1.15+ |

You will also need an Apple Developer account in order to sign and run the app on
a physical device or use entitlements such as Network Extensions (required by the
WireGuard tunnel) and App Groups (required by the widget).

## Project Layout

```
Glacier/
  Application/      App entry point, AppDelegate, root coordinators
  Core/             Managers, services, models, networking, extensions
  Modules/          Feature modules (Auth, Home, Phone, Settings, Onboarding…)
  Resources/        Assets, audio, fonts, localizations, video, schema
WireGuardNetworkExtension/   Packet tunnel + DNS proxy network extensions
GlacierWidget/      Home Screen / Lock Screen widget
GlacierTests/       Unit tests
```

## Build Instructions

### 1. Install CocoaPods

```bash
gem install cocoapods
```

### 2. Clone and install pods

```bash
git clone https://github.com/A-Security-App/glacierApp.git
cd glacierApp
pod install
```

> **Always open `Glacier.xcworkspace`, not `Glacier.xcodeproj`** — CocoaPods'
> dependencies are wired up through the workspace.

### 3. Provide local `Secrets.plist` files

Two `Secrets.plist` files need to be created from their templates. Both are
gitignored — they hold environment-specific endpoint configuration.

```bash
cp Glacier/Resources/Properties/Secrets-template.plist Glacier/Resources/Properties/Secrets.plist
cp WireGuardNetworkExtension/Secrets-template.plist    WireGuardNetworkExtension/Secrets.plist
```

Then edit each file and fill in the placeholder values. The main app expects:

| Key | Meaning |
| --- | --- |
| `consoleBaseEndpoint` | Base URL of your Glacier console / API gateway, e.g. `https://console.example.com/api/v1/` |
| `twilioAPIEndpoint` | Path appended to `consoleBaseEndpoint` for the Twilio token / messaging API |
| `wgProfileEndpoint` | Path that returns the WireGuard `.conf` profile URL |
| `dnsProfileEndpoint` | Path that returns DNS profile/user info |
| `dnsEndpoint` | DNS-over-TLS server suffix (e.g. `.dns.example.com`) |
| `dnsAPIEndpoint` | Path used for DNS analytics / tracker counts |
| `dnsCheckEndpoint` | Hostname used by the DNS health check |
| `dnsCheckIP` | Expected resolved IP for `dnsCheckEndpoint` |
| `subscriptionEndpoint` | Path that returns the current subscription / entitlement state |

The WireGuard extension only needs `dnsEndpoint`.

### 4. Provide an Amplify configuration

Glacier uses [AWS Amplify](https://docs.amplify.aws) (Cognito) for user sign-on.
You will need to create your own Amplify project and drop the generated
`amplifyconfiguration.json` into:

```
Glacier/Application/Configuration/amplifyconfiguration.json
```

This path is gitignored. At a minimum the configuration must define an
`awsCognitoAuthPlugin` with both a User Pool and an Identity Pool. If you want
to use Hosted UI (Apple / Google sign-in), include an `OAuth` block whose
`SignInRedirectURI` and `SignOutRedirectURI` match the app's URL scheme
(`glacierapp://`).

A minimal `amplifyconfiguration.json` looks like:

```json
{
  "UserAgent": "aws-amplify-cli/2.0",
  "Version": "1.0",
  "auth": {
    "plugins": {
      "awsCognitoAuthPlugin": {
        "UserAgent": "aws-amplify-cli/2.0",
        "Version": "1.0",
        "CredentialsProvider": {
          "CognitoIdentity": { "Default": { "PoolId": "<region:identity-pool-id>", "Region": "<region>" } }
        },
        "CognitoUserPool": {
          "Default": { "PoolId": "<user-pool-id>", "AppClientId": "<app-client-id>", "Region": "<region>" }
        },
        "Auth": {
          "Default": {
            "OAuth": {
              "WebDomain": "<cognito-hosted-ui-domain>",
              "AppClientId": "<app-client-id>",
              "SignInRedirectURI": "glacierapp://",
              "SignOutRedirectURI": "glacierapp://",
              "Scopes": ["openid", "email", "profile"],
              "ResponseType": "code"
            },
            "mfaConfiguration": "OFF",
            "passwordProtectionSettings": { "passwordPolicyMinLength": 8, "passwordPolicyCharacters": [] }
          }
        }
      }
    }
  }
}
```

### 5. Set your signing team

The repository ships with the original Glacier Security team ID. Before you can
build for a device or for TestFlight, update the team for each target:

1. Open `Glacier.xcworkspace` in Xcode.
2. Select the **Glacier** project in the navigator.
3. For each target (`Glacier`, `GlacierWidget`, `WireGuardNetworkExtension`,
   `GlacierTests`), open **Signing & Capabilities** and replace **Team** with
   your own Apple Developer team.
4. You may also need to change the bundle identifiers (e.g.
   `com.theglacierapp.Glacier`) so they are unique to your account.

### 6. Build

Open `Glacier.xcworkspace` and run the **Glacier** scheme on the simulator or
on a connected device.

## Running the Tests

The test target is `GlacierTests`. From the command line:

```bash
xcodebuild test \
  -workspace Glacier.xcworkspace \
  -scheme GlacierTests \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Or in Xcode: select the **GlacierTests** scheme and press ⌘U.

## Pinned Endpoints

Glacier enforces SSL public-key pinning on every outbound HTTPS connection via
[`GlacierPinningConfiguration`](Glacier/Core/Networking/GlacierPinningConfiguration.swift).
If you point the app at infrastructure that does not use Amazon Trust Services
or Google Trust Services as a root, add the SPKI SHA-256 hash of your CA's
public key to `GlacierPinningConfiguration.pinnedHashes`. Instructions for
generating a hash from a live endpoint are at the top of that file.

## Vendored Binaries

The WireGuard data path is implemented in Go and ships as a pre-built static
library. Two universal `libwg-go.a` files are checked in:

- [`Glacier/Scripts/libwg-go.a`](Glacier/Scripts/libwg-go.a) — device build
  (`arm64` + `x86_64`), linked into `WireGuardNetworkExtension` builds for
  iPhone/iPad hardware.
- [`Glacier/Includes-Simulator/libwg-go.a`](Glacier/Includes-Simulator/libwg-go.a) —
  Simulator build (`arm64` + `x86_64`), linked into Simulator builds.

Both are produced from the `WireGuardKitGo` target inside the
[wireguard-apple](https://github.com/WireGuard/wireguard-apple) Swift package,
which is pulled in as an SPM dependency (see `Package.resolved`). Checking the
binaries in lets contributors build the app without installing Go.

To regenerate them from source, install Go (`brew install go`) and run
[`Glacier/Scripts/build_wireguard_go_bridge.sh`](Glacier/Scripts/build_wireguard_go_bridge.sh)
after at least one Xcode build has fetched the SPM checkout. The script `cd`s
into the `WireGuardKitGo` directory in the SPM checkout and runs `make`, which
emits an architecture-matched `libwg-go.a` into the build directory. Copy the
result over the checked-in copies. The script is also wired into the Xcode
project as a `PBXLegacyTarget` (`WireGuardGoBridge`) that runs on every build,
but its output is currently informational only — the linker pulls from the
checked-in copies via `LIBRARY_SEARCH_PATHS`.

## License

Glacier source code is published under the **Source Available License**
(see [`LICENSE`](LICENSE)). In short: you may view and fork the code for
personal, non-commercial review or security research; you may not use, copy,
modify, redistribute, or sublicense it for commercial purposes without
written permission from Security App, LLC. Vulnerability reports submitted
under our [Security Policy](SECURITY.md) are explicitly allowed to include
reproduction code.

### Third-Party Components

The repository includes code and binaries that remain under their own
upstream licenses:

| Component | Location | License | Upstream |
| --- | --- | --- | --- |
| WireGuard sample tunnel files | `WireGuardNetworkExtension/Shared/**` | MIT (© 2018–2023 WireGuard LLC) | [WireGuard/wireguard-apple](https://github.com/WireGuard/wireguard-apple) |
| `libwg-go.a` static libraries | `Glacier/Scripts/`, `Glacier/Includes-Simulator/` | MIT (© WireGuard LLC) | Built from `WireGuardKitGo` in [WireGuard/wireguard-apple](https://github.com/WireGuard/wireguard-apple) |
| CocoaPods dependencies | `Pods/` (not checked in) | Various; see [`license_plist.yml`](license_plist.yml) | per-pod |
| Swift Package Manager dependencies | resolved via `Package.resolved` | Various; see each package's repository | per-package |

The full upstream copyright notices and license texts for the
redistributed WireGuard files and binaries are reproduced in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md). Per-file SPDX headers
are preserved in the WireGuard source files as required by the MIT
license. Nothing in this repository incorporates code under a copyleft
license such as GPL or AGPL.
