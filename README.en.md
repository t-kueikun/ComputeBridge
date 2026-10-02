# ComputeBridge

[日本語](README.md) | English

[![Build](https://github.com/t-kueikun/ComputeBridge/actions/workflows/build.yml/badge.svg)](https://github.com/t-kueikun/ComputeBridge/actions/workflows/build.yml)

**An experimental Mac and iPhone app that distributes compute jobs to nearby Apple devices.**

The Mac acts as the coordinator and iPhones act as workers. ComputeBridge sends Monte Carlo π estimation jobs over the local network. It does not move other Mac applications or their memory to another device. It distributes only computations explicitly submitted to ComputeBridge.

> Experimental feature: ComputeBridge can also run supported Next.js 15 and 16 development servers in an embedded Node.js 24 runtime on an iPhone. It is not a general purpose process, CPU, or RAM offload layer.

## Quick start

Requirements: Xcode 16 or later, macOS 14 or later, iOS 17 or later, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/t-kueikun/ComputeBridge.git
cd ComputeBridge
brew install xcodegen
xcodegen generate
open ComputeBridge.xcodeproj
```

Run the `ComputeBridgeMac` scheme on the Mac. To install the worker on a physical iPhone, select the `ComputeBridgeiOS` target, choose your Apple Development team, and change the bundle identifier if Xcode reports that the default identifier is unavailable. Allow Local Network access in both apps and keep the iPhone app in the foreground while it is working.

The repository includes the NodeMobile XCFramework and the SWC WASM runtime required by the prototype. Their licenses are stored under `Vendor` and `ComputeBridge/NodeProbe/Runtime/swc-wasm-nodejs`.

## Features

- SwiftUI macOS coordinator and iOS worker apps
- Automatic discovery through Bonjour (`_computebridge._tcp`) and connections through Network.framework
- Capability exchange plus worker battery and thermal state display
- Benchmarks on the Mac, on a worker, or across the Mac and all connected workers
- Work allocation across multiple workers based on their CPU core counts
- π estimate, execution time, and speedup relative to a Mac-only run with the same iteration count
- Mac CPU and memory usage display
- Error recovery for an active distributed benchmark when a worker disconnects
- Wired connection over iPhone USB Personal Hotspot on port 43182
- Next.js 15 and 16 development server startup from Node.js 24 inside the existing worker app
- Transfer of a Next.js folder selected on the Mac, followed by synchronization of source changes

The benchmark uses a Swift CPU implementation. GPU and Metal computation, Core ML, automatic scheduling, and arbitrary process offloading are not implemented. Because of iOS execution restrictions, the worker app must remain open in the foreground while a job is running.

## Next.js on iPhone prototype

Install the existing `ComputeBridgeiOS` scheme on an iPhone from Xcode. In the worker app, press `Start runtime` under `NEXT.JS DEVELOPMENT`. Scan the QR code shown on the iPhone from `NEXT.JS ON IPHONE` → `Scan QR` in the Mac app. This fills in the Wi-Fi address and pairing token automatically. Allow camera access on the Mac the first time. Choose a project folder and press `Send and run`. After startup, use `Open site` to open the development server running on the iPhone.

Source changes are synchronized while the Mac app remains open. Pressing `Stop Next.js` on the iPhone stops both the development server and Mac-side source synchronization while leaving the transfer runtime active. A transferred project can be restarted with `Start Next.js`. You can also type the address and token instead of scanning the QR code. For USB Personal Hotspot, enter the USB-side IP address manually. The token and QR code change when the iPhone app restarts.

To perform the same operation from the command line:

```sh
python3 scripts/send-next-project.py '/path/to/your-next-project' --host IPHONE_IP --token PAIRING_TOKEN
```

The prototype targets Next.js 15 and 16. Next.js 16 runs with Webpack and requires a matching version of `@next/swc-wasm-nodejs`. If that package is not present on the Mac, the transfer script downloads it from the npm registry and adds it to the iPhone archive. The Mac project must already have `node_modules` installed.

The iPhone does not launch the `npm run dev` command itself. ComputeBridge starts the Next.js development server directly from the same Node.js process. Workarounds for parts of Next.js that do not support iOS are applied only to the copy on the device; the source folder on the Mac is not modified. Next.js 16 TypeScript configuration is also parsed with the in-process TypeScript API instead of a child process. `.env*`, `.npmrc`, `.git`, and `.next` are excluded from transfer, so authentication, payment, and database operations need separate configuration. Keep the iPhone app in the foreground.

In the simulator, the prototype transferred the 130 MB Notch Web project, started Next.js, returned HTTP 200 from `/notch/`, returned the expected unauthenticated HTTP 401 from an authentication API, recompiled an edited page, and added a new route. On a physical iPhone, it transferred the 130.4 MB project to the existing worker and returned HTTP 200 from `/notch/` and the expected unauthenticated HTTP 401 from the authentication API. See [docs/npm-offload-blockers.md](docs/npm-offload-blockers.md) for limitations.

A minimal App Router project using Next.js 16.3.8 with the matching SWC WASM version also returned HTTP 200 from a Webpack development server on a physical iPhone. Stopping the server from the iPhone was verified as well. The main Notch Web project remains on Next.js 15.

## Setup

Requirements: Xcode 16 or later, macOS 14 or later, iOS 17 or later, and XcodeGen.

```sh
xcodegen generate
open ComputeBridge.xcodeproj
```

In Xcode, run `ComputeBridgeMac` on the Mac and `ComputeBridgeiOS` on the iPhone. Configure development signing for the iPhone and allow Local Network access in both apps. Connect both devices to the same LAN or Wi-Fi network and keep the iPhone app open. The worker will appear in the Mac app.

For a wired connection, enable Allow Others to Join under Settings → Personal Hotspot on the iPhone, connect it to the Mac with a USB cable, and approve Trust This Computer. In the worker section of the Mac app, enter the USB destination address, which defaults to `172.20.10.1`, and press `Connect`. Confirm that iPhone USB appears as connected under System Settings → Network in macOS.

To build from the command line:

```sh
xcodebuild -project ComputeBridge.xcodeproj -scheme ComputeBridgeMac -destination 'platform=macOS' build
xcodebuild -project ComputeBridge.xcodeproj -scheme ComputeBridgeiOS -destination 'generic/platform=iOS Simulator' build
```

## Usage

1. Wait for the iPhone to show `Ready` in the worker section of the Mac app.
2. Choose an iteration count and a benchmark target: `This Mac`, `Worker`, or `Distributed`.
3. Press `Run benchmark`.
4. Compare execution time and speedup relative to the Mac-only run in Run History.

`Distributed` assigns iterations to the Mac and every connected worker, then combines their results. Speedup uses a previous `Mac only` run with the same iteration count as its baseline. The supported range is 10,000 to 200,000,000 iterations.

## Networking and limitations

Shared models and compute code live in `ComputeBridge/Shared` and are used by both the Mac and iOS targets. Connected apps exchange newline-delimited JSON messages. A benchmark request contains only job metadata, so the benchmark does not transfer a large input dataset.

Normal connections use Bonjour. Wired connections use TCP on port `43182` over iPhone USB Personal Hotspot, with the wired Ethernet interface selected on the Mac. The address can be changed for a different network configuration. The current protocol does not provide encryption or authentication. Use it only on a trusted network. If a worker disconnects, an active benchmark ends with an error and is not automatically rerun on the Mac.

## Project structure

```text
ComputeBridge/
├── Shared/   Protocol, messages, π computation, Network.framework transport
├── Mac/      Coordinator, resource monitor, benchmark UI
└── iOS/      Worker, capability collection, worker UI
```

`project.yml` defines the Xcode project for XcodeGen. The Mac app, worker app, and simulator-only NodeProbe target share one Xcode project. Use `ComputeBridgeiOS` on a physical device. On the first build, select your Apple Development team and, if necessary, change the bundle identifier in `project.yml` before running `xcodegen generate` again. The Node iOS framework and its licenses are under `Vendor`; transfer scripts are under `scripts`.

## License

Original ComputeBridge code is available under the [MIT License](LICENSE). Bundled third-party components remain subject to their respective licenses.
