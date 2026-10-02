# iOS JavaScript runtime research (2026-09-30)

## Decision

Use the system JavaScriptCore framework for the first on-device JavaScript PoC. It is already present on iOS, embeds directly in Swift, and executes ECMAScript without downloading a runtime. The PoC captures `console.log`, `console.error`, and `console.warn` and returns them to the Mac over the existing ComputeBridge JSON-lines connection.

This is a JavaScript engine, not a Node.js runtime. The separate port-3000 PoC is a native Network.framework HTTP listener. Neither component provides `npm`, `process`, Node's `fs`/`net`/`http` modules, npm package resolution, or Vite's Node server. Passing these two PoCs does not mean `npm run dev` can run on the phone.

## Candidate comparison

| Runtime | Node API / npm | Modules | Filesystem, HTTP, WebSocket, watch | Native modules | JIT / iOS / background | License / decision |
|---|---|---|---|---|---|---|
| JavaScriptCore (Apple) | None; no Node compatibility | Modern JavaScript engine, but not a Node module loader | Must be supplied by the host app; the PoC only adds `console` and a separate native HTTP listener | Swift/Objective-C bridge is available; not Node-API addons | iOS system framework; JIT behavior is OS-managed. App must remain foreground for this worker. | Apple system framework; best smallest supported JS execution PoC. |
| QuickJS | None; no npm or Node API | ES modules supported | Small `std`/`os` library in standalone interpreter; filesystem/network integration needs native work. No drop-in Node HTTP/WebSocket or file watcher. | QuickJS C API modules, not Node addons | Interpreter can run without a JIT; app lifecycle and networking remain iOS constrained. | MIT; viable compact custom runtime, but would require more integration work than JSC. |
| Node.js upstream | This is the needed API surface, but upstream's supported build matrix does not include iOS | CommonJS / ESM according to Node | Provides the relevant APIs on supported platforms | Node-API addons are platform/ABI-specific | V8/JIT, mobile signing, app lifecycle and background limits require a maintained iOS port | No first-party supported iOS target was found; not selected as an app-embedded runtime. |
| Node.js for Mobile Apps (`nodejs-mobile`) | Embedded Node API, with mobile restrictions including unavailable child process creation | CommonJS and ESM | Node filesystem and networking in the app sandbox; package compatibility still varies | Native modules need iOS builds | iOS framework uses jitless V8; app lifecycle still applies | Third-party project. The maintained fork `fogtape/nodejs-mobile` published a Node 24.21.0 iOS XCFramework on 2026-09-14. It is a plausible Node prototype, but it does not make arbitrary `npm run dev` scripts compatible. |
| WebAssembly runtimes | No Node API or npm by themselves | Depends on embedded JS engine; WASM runtime is not a JS runtime | Host must implement system calls and network/filesystem | WASI or custom host imports, not Node addons | iOS-compatible interpreters exist; background rules remain | Not a shortcut to Node/Vite compatibility. |

## Vite compatibility gate

Vite is a Node-based tool and expects Node APIs and package dependencies. JavaScriptCore can execute a snippet, but cannot directly launch `npm run dev`. QuickJS has ES module support but does not supply Node's built-ins. A current mobile Node port now exists, correcting the earlier Node 12-only finding. However, `npm run dev` normally starts the configured command as a child process, and the mobile Node FAQ says `child_process.spawn()` and `fork()` run into mobile OS permission issues. An embedded app would need to invoke a supported dev server programmatically in the same Node process.

That still does not establish Vite support. Vite 8 uses Rolldown/Oxc native tooling. Rolldown's published native platform list does not include iOS. Its Wasm fallback targets WASI with threads, while the mobile iOS Node build runs jitless V8 with a limited JavaScript WebAssembly polyfill that does not support threads. Vite 7 uses esbuild, whose Node API starts a binary through `child_process.spawn()`. Therefore neither path currently offers a demonstrated iPhone Vite dev server. A physical-device compatibility prototype would be required before promising it in the UI.

The Node 24 compatibility spike is now implemented as a separate app target. It ran a pure-JavaScript HTTP server and a Next.js 15 development server in the iOS Simulator. The selected `Notch Web` project was also transferred and served there; details and remaining physical-device limits are in `npm-offload-blockers.md`. JavaScriptCore remains the runtime for the original small-snippet Worker, while the Next.js prototype uses embedded Node.

## Sources

- [Apple JavaScriptCore overview](https://developer.apple.com/documentation/javascriptcore) — embedding and evaluating JavaScript in an app.
- [Apple JSContext reference](https://developer.apple.com/documentation/javascriptcore/jscontext) — evaluate scripts and access the JavaScript environment.
- [QuickJS manual](https://bellard.org/quickjs/quickjs.html) — language support, ES modules, standard library, and MIT license.
- [Node.js build platforms](https://github.com/nodejs/node/blob/main/BUILDING.md) — upstream supported platform matrix.
- [Node.js for Mobile Apps repository](https://github.com/nodejs-mobile/nodejs-mobile) — project scope and iOS binaries.
- [Mobile Node 24.21.0 release](https://github.com/fogtape/nodejs-mobile/releases/tag/v24.21.0-0) — current iOS XCFramework candidate.
- [Mobile Node FAQ](https://github.com/fogtape/nodejs-mobile/blob/recipe/docs/FAQ.md) — child-process, JIT, Wasm, and native-module limits.
- [Vite 8 migration guide](https://vite.dev/guide/migration.html) — Rolldown replaces esbuild for dependency optimization.
- [Rolldown supported platforms](https://github.com/rolldown/rolldown/blob/main/docs/guide/getting-started.md) — iOS is absent from published native binaries.
- [esbuild Node API source](https://github.com/evanw/esbuild/blob/main/lib/npm/node.ts) — it starts a separate binary with `child_process.spawn()`.
- [Apple local-network privacy note](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — permission behavior; local-network tests must be performed on a physical device.
