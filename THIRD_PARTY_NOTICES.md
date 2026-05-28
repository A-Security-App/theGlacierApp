# Third-Party Notices

This file records the copyright notices and license terms of third-party
components redistributed inside this repository. It exists to satisfy the
attribution requirements of the upstream licenses.

The project source itself is published under the [Source Available
License](LICENSE); the components listed below remain under their own
licenses regardless of the project license.

---

## WireGuard (MIT)

The following files in this repository are derived from, or built from
sources in, the [wireguard-apple](https://github.com/WireGuard/wireguard-apple)
project and remain subject to the MIT license below.

**Files redistributed as source:**

- `WireGuardNetworkExtension/Shared/FileManager+Extension.swift`
- `WireGuardNetworkExtension/Shared/Keychain.swift`
- `WireGuardNetworkExtension/Shared/NotificationToken.swift`
- `WireGuardNetworkExtension/Shared/Model/NETunnelProviderProtocol+Extension.swift`
- `WireGuardNetworkExtension/Shared/Model/String+ArrayConversion.swift`
- `WireGuardNetworkExtension/Shared/Model/TunnelConfiguration+WgQuickConfig.swift`

**Binaries built from the WireGuardKitGo target of wireguard-apple:**

- `Glacier/Scripts/libwg-go.a` (device, universal)
- `Glacier/Includes-Simulator/libwg-go.a` (Simulator, universal)

**License:**

```
Copyright (c) 2018-2023 WireGuard LLC <team@wireguard.com>. All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## Swift Package Manager Dependencies

Resolved at build time from `Package.resolved`; their source is not vendored
into this repository. Each upstream repository ships its own LICENSE file,
which Xcode fetches alongside the package source. The set includes (but is
not limited to):

- [wireguard-apple](https://github.com/WireGuard/wireguard-apple) (MIT)
- [amplify-swift](https://github.com/aws-amplify/amplify-swift) (Apache 2.0)
- [aws-crt-swift](https://github.com/awslabs/aws-crt-swift) (Apache 2.0)
- [grpc-swift](https://github.com/grpc/grpc-swift) (Apache 2.0)
- [lottie-spm](https://github.com/airbnb/lottie-spm) (Apache 2.0)
- Apple Swift packages (`swift-nio`, `swift-protobuf`, `swift-system`,
  `swift-atomics`, `swift-algorithms`, `swift-argument-parser`,
  `swift-http-types`, `swift-http-structured-headers`, etc.) — Apache 2.0
- [Thrift-Swift](https://github.com/undefinedlabs/Thrift-Swift) (Apache 2.0)
- [opentelemetry-swift](https://github.com/open-telemetry/opentelemetry-swift)
  (Apache 2.0)
- [amplify-ui-swift-authenticator](https://github.com/aws-amplify/amplify-ui-swift-authenticator)
  (Apache 2.0)

See each upstream repository for the authoritative license text.

---

## CocoaPods Dependencies

Resolved via `pod install` from [`Podfile`](Podfile); their source is not
vendored into this repository. Each pod ships its own LICENSE file inside
its installed `Pods/<Name>/` directory. The set includes:

- Alamofire (MIT)
- BBlock (MIT)
- GRDB.swift / SQLCipher (MIT)
- IOSSecuritySuite (MIT)
- JWTDecode (MIT)
- Kingfisher (MIT)
- MBProgressHUD (MIT)
- SAMKeychain (MIT)
- SQLCipher (BSD-style; see Pods/SQLCipher/LICENSE)
- TwilioVoice (proprietary, redistributable per Twilio's terms)

See each pod's installed LICENSE for the authoritative text.
[`license_plist.yml`](license_plist.yml) configures
[LicensePlist](https://github.com/mono0926/LicensePlist) to generate the
in-app "Licenses" Settings entries from these.
