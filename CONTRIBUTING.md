# Contributing

Issues and pull requests are welcome.

## Development setup

1. Install Xcode 16 or later and XcodeGen.
2. Run `xcodegen generate`.
3. Open `ComputeBridge.xcodeproj`.
4. Build `ComputeBridgeMac` for macOS.
5. To run the iOS app on a device, select your Apple Development team and use bundle identifiers available to that team.

## Pull requests

- Keep changes focused and describe the user-visible behavior.
- Do not commit `.env` files, signing credentials, provisioning profiles, or Xcode user data.
- Verify the macOS target builds before opening a pull request.
- For iOS or Next.js runtime changes, include the tested iOS, Node.js, and Next.js versions.

## Third-party code

ComputeBridge bundles NodeMobile, SWC WASM, and small npm runtime dependencies. Preserve their license files when updating these components.
