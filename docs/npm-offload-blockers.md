# Next.js development on iPhone (2026-10-01)

## What has been demonstrated

- The `ComputeBridgeNodeProbe` iOS Simulator prototype embeds the third-party Node.js 24.21.0 mobile XCFramework. Its HTTP endpoint reported `process.platform === "ios"` and returned HTTP 200. The runtime has since also been integrated into the existing `ComputeBridgeiOS` Worker target.
- Next.js 15.5.18 started inside this Node process without invoking `npm` or `child_process.fork()`. The minimal React page compiled and returned HTTP 200.
- The Mac transfer script sent a 130.4 MB compressed Next.js project to the simulator app. The phone-side Node process extracted it and launched the Next.js development server on port 3001. A page returned HTTP 200, and an authenticated API route compiled and returned the expected HTTP 401 without a session token.
- Source edits sent through the transfer endpoint changed the rendered page. A new route also appeared after polling-based file watching was enabled.
- The physical iPhone Worker received the 130.4 MB Notch Web archive over Wi-Fi, started Next.js, returned HTTP 200 for `/notch/`, and returned the expected unauthenticated HTTP 401 for `/api/account/licenses/`.
- The Mac Coordinator has a folder picker, QR scanner, transfer address and pairing token fields, and controls for transfer, launch, source sync, and opening the site.
- Next.js 16.3.8 served a minimal App Router page with HTTP 200 on a physical iPhone. Next.js 16.3.5 also reached and maintained the `ready` state for a larger project after its TypeScript configuration path was adapted for iOS.

## Compatibility changes made in the iPhone copy

1. Next.js 15 sets `process.title` during startup. The embedded iOS Node build crashed on that setter in the simulator, so the iPhone copy skips that assignment.
2. Next.js has no native SWC binary for iOS. The app bundles the matching `@next/swc-wasm-nodejs` 15.5.18 package and points Next to it.
3. Next.js CLI normally forks its server. The iPhone app calls `startServer()` in its existing Node process.
4. Next's default file watcher did not see simulator edits. The app sets `WATCHPACK_POLLING=1000`; page edits and new routes were then detected.
5. The app enables worker threads in Next's local default config copy to avoid child-process work in development tasks.
6. Next.js 16 enables its TypeScript CLI path by default. On iOS, spawning `tsc --showConfig` fails with `EPERM`, so the transferred copy uses the in-process TypeScript compiler API instead.

The Mac project folder is not modified. The transfer omits `.env*`, `.npmrc`, `.git`, and `.next`; secrets and deployment state stay on the Mac. The session uses a per-launch pairing token over local HTTP. The token protects the project transfer and source-edit endpoints, but HTTP traffic itself is not encrypted.

## Remaining limits

- The updated existing Worker built and installed under its stable `dev.computebridge.ios` bundle ID and existing profile. After the device was unlocked, the physical iPhone launched embedded Node 24.21.0 and its port-3100 status endpoint returned HTTP 200 with `platform: ios` and `architecture: arm64`.
- An earlier 130.4 MB upload stalled after the phone locked. With the Worker in the foreground and its idle timer disabled, the retry completed and the physical Next.js page responded. This does not establish background execution support.
- The separate probe bundle ID cannot currently be signed because the Xcode Apple account requires sign-in. The existing Worker uses its saved provisioning profile, so it can be built without creating a new app ID. The project's `DEVELOPMENT_TEAM` now matches that profile.
- This prototype targets Next.js 15 and 16 in Webpack mode. Turbopack, projects with native addons, postinstall tooling, and arbitrary `npm run dev` commands are not supported.
- `node_modules` must already exist on the Mac and is transferred to the iPhone. Native macOS binaries in it do not become iOS binaries. The selected Notch Web pages exercised here did not need them.
- The app must remain in the foreground. iOS background execution is not a general-purpose development server environment.
- Notch Web's Clerk, Stripe, and Neon credentials are in excluded environment files. The HTTP 401 route check did not exercise authenticated, payment, or database operations.
- File synchronization currently polls the Mac folder every second; an initial transfer is needed each time the iPhone project is replaced. The CLI watches source edits after startup; the Mac GUI runs that CLI in the background.
- Disk space can be substantial: the copied Notch Web project includes about 372 MB of `node_modules`, plus build output, the compressed upload, and the app runtime.

## Sources

- [Mobile Node 24.21.0 release](https://github.com/fogtape/nodejs-mobile/releases/tag/v24.21.0-0)
- [Mobile Node FAQ](https://github.com/fogtape/nodejs-mobile/blob/recipe/docs/FAQ.md)
- [Next.js supported development systems](https://nextjs.org/docs/pages/getting-started/installation)
- [Next.js SWC native binding matrix](https://github.com/vercel/next.js/blob/canary/packages/next-swc/README.md)
- [Next.js file-watching discussion](https://github.com/vercel/next.js/discussions/86363)

See [js-runtime-research.md](js-runtime-research.md) for the broader runtime candidates.
