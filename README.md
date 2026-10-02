# ComputeBridge

[![Build](https://github.com/t-kueikun/ComputeBridge/actions/workflows/build.yml/badge.svg)](https://github.com/t-kueikun/ComputeBridge/actions/workflows/build.yml)

**近くのAppleデバイスへ計算Jobを分散する、Mac / iPhone向け実験アプリ。**

MacをCoordinator、iPhoneをWorkerとして、Monte Carlo法でπを推定するJobをローカルネットワーク経由で実行します。Mac上の他のアプリやメモリを別端末へ移すものではなく、ComputeBridgeに明示的に渡した計算だけを分散します。

> Experimental: ComputeBridge also runs supported Next.js 15/16 development servers inside an embedded Node.js 24 runtime on an iPhone. It is not a general-purpose process, CPU, or RAM offload layer.

## Quick start (English)

Requirements: Xcode 16+, macOS 14+, iOS 17+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
git clone https://github.com/t-kueikun/ComputeBridge.git
cd ComputeBridge
brew install xcodegen
xcodegen generate
open ComputeBridge.xcodeproj
```

Run the `ComputeBridgeMac` scheme on the Mac. To install the Worker on a physical iPhone, select the `ComputeBridgeiOS` target, choose your Apple Development team, and change the bundle identifier if Xcode reports that the default identifier is unavailable. Allow Local Network access in both apps and keep the iPhone app in the foreground while it is working.

The repository includes the NodeMobile XCFramework and the SWC WASM runtime required by the prototype. Their licenses are stored under `Vendor` and `ComputeBridge/NodeProbe/Runtime/swc-wasm-nodejs`.

## 実装した機能

- SwiftUI製のmacOSアプリとiOS Workerアプリ
- Bonjour (`_computebridge._tcp`) による自動検出とNetwork.framework接続
- Capability交換とWorkerのバッテリー / thermal state表示
- Mac単体、Worker単体、Mac + 接続済みWorkerのベンチマーク
- 複数WorkerへのCPUコア数に基づく試行回数の配分
- π推定値、実行時間、同じ試行数でのMac単体比を表示
- MacのCPU / メモリ使用量を表示
- Worker切断時に進行中の分散ベンチマークをエラーとして回収
- iPhoneのUSBインターネット共有を使った有線接続（ポート43182）
- 既存Workerアプリ内で、Next.js 15/16開発サーバーをiPhone側のNode 24から起動
- Macで選んだNext.jsフォルダの転送と、その後のソース変更の同期

計算はSwiftによるCPU実装です。GPU / Metal、Core ML、自動Scheduler、任意プロセスのオフロードは未実装です。iOSの実行制約に合わせ、WorkerアプリはJob実行中にフォアグラウンドで開いておきます。

## Next.jsをiPhoneで動かす試作

Xcodeで既存の`ComputeBridgeiOS`スキームをiPhoneへインストールし、Worker画面の`NEXT.JS DEVELOPMENT`で`Start runtime`を押します。iPhoneに表示されたQRコードをMacアプリの`NEXT.JS ON IPHONE`→`Scan QR`で読み取ると、Wi-Fiアドレスとペアリングトークンが自動入力されます。初回はMacのカメラ使用を許可してください。プロジェクトフォルダを選んで`Send and run`を押します。起動後、`Open site`でiPhone上の開発サーバーを開けます。ソース変更はMacアプリが開いている間に同期されます。iPhoneの`Stop Next.js`を押すと開発サーバーとMac側のソース同期が停止し、転送用ランタイムは残ります。転送済みのプロジェクトは`Start Next.js`で再開できます。QRを使わずにアドレスとトークンを手入力することもできます。USBインターネット共有ではUSB側のIPアドレスを手入力してください。iPhoneアプリを再起動するとトークンとQRコードは変わります。

コマンドラインから同じ操作をする場合：

```sh
python3 scripts/send-next-project.py '/path/to/your-next-project' --host IPHONE_IP --token PAIRING_TOKEN
```

この試作はNext.js 15と16を対象にしています。16はWebpackで動作し、同じバージョンの`@next/swc-wasm-nodejs`が必要です。Mac側にない場合、転送時にnpmレジストリから取得してiPhone向けアーカイブへ追加します。Macに`node_modules`がインストールされている必要があります。`npm run dev`コマンド自体はiPhoneで起動せず、Nodeの同一プロセス内からNext.jsの開発サーバーを直接起動します。NextのiOS非対応部分には端末内のコピーだけで回避策を適用し、Macの元フォルダは変更しません。Next.js 16のTypeScript設定解析も子プロセスを使わず、同一プロセス内のTypeScript APIで実行します。`.env*`、`.npmrc`、`.git`、`.next`は転送しません。そのため認証・決済・データベースの実際の操作には別途設定が必要です。iPhoneアプリは前面で開いてください。

シミュレータでは、Notch Webの130 MB転送、Next.js起動、`/notch/`のHTTP 200、認証APIの未認証401、編集したページの再コンパイルと新規ルートの追加を確認しました。実機でも既存Workerへ130.4 MBのNotch Webを転送し、iPhone上のNext.jsから`/notch/`のHTTP 200と認証APIの未認証401を確認しました。制限は[docs/npm-offload-blockers.md](docs/npm-offload-blockers.md)を参照してください。
Next.js 16.3.8と同じバージョンのSWC WASMを使う最小App Routerプロジェクトでも、実機iPhoneのWebpack開発サーバーからトップページのHTTP 200を確認しました。iPhone側の停止操作も確認済みです。Notch Web本体はNext.js 15のままです。

## 起動方法

必要環境：Xcode 16以降、macOS 14以降、iOS 17以降、XcodeGen。

```sh
xcodegen generate
open ComputeBridge.xcodeproj
```

Xcodeで`ComputeBridgeMac`をMacへ、`ComputeBridgeiOS`をiPhoneへ実行します。iPhone側の開発者署名を設定し、両方のアプリでローカルネットワークの許可を承認してください。2台を同じLAN / Wi-Fiへ接続し、iPhoneアプリを開いたままにするとMac側にWorkerが表示されます。有線の場合はiPhoneの「設定 > インターネット共有」で「ほかの人の接続を許可」をオンにし、USBケーブルでMacへ接続して「このコンピュータを信頼」を許可します。MacアプリのWorker欄でUSB接続先アドレス（初期値`172.20.10.1`）を指定して`Connect`を押します。macOSの「システム設定 > ネットワーク」にiPhone USBが接続済みと表示されることを確認してください。

コマンドラインでビルドする場合：

```sh
xcodebuild -project ComputeBridge.xcodeproj -scheme ComputeBridgeMac -destination 'platform=macOS' build
xcodebuild -project ComputeBridge.xcodeproj -scheme ComputeBridgeiOS -destination 'generic/platform=iOS Simulator' build
```

## 使い方

1. MacアプリのWorker欄でiPhoneが`Ready`になるのを待つ。
2. 試行回数と実行先（`This Mac`、`Worker`、`Distributed`）を選ぶ。
3. `Run benchmark`を押す。
4. Run Historyで実行時間とMac単体に対する速度比を比較する。

`Distributed`はMacと接続中の全Workerへ試行を割り当て、各端末の結果を合算します。速度比は同じ試行数で先に測った`Mac only`を基準にします。試行回数は10,000から200,000,000です。

## 通信と制約

共有モデル・計算コードは`ComputeBridge/Shared`にあり、MacとiOSの両ターゲットから利用します。接続中のアプリ間でJSONメッセージを改行区切りで交換します。ベンチマーク入力はJobメタデータだけなので、大きなデータは転送しません。

接続先は通常接続はBonjourを使います。有線接続はiPhone USBインターネット共有上のTCP接続（ポート`43182`）を使い、Mac側で有線Ethernetインターフェースを指定します。アドレスはネットワーク構成に合わせて編集できます。現在のプロトコルは暗号化・認証を行いません。信頼できるネットワーク内でのみ使用してください。Workerが切断されると進行中のベンチマークはエラーになり、Mac上では自動再実行しません。

## 構成

```text
ComputeBridge/
├── Shared/   プロトコル、メッセージ、π計算、Network.framework transport
├── Mac/      Coordinator、Resource Monitor、ベンチマークUI
└── iOS/      Worker、Capability収集、Worker UI
```

`project.yml`がXcodeGenのプロジェクト定義です。Mac、Worker、シミュレータ試作用NodeProbeの3ターゲットは同じXcodeプロジェクト内にあります。実機では`ComputeBridgeiOS`を使います。初回は自分のApple Development Teamを選択し、必要に応じて`project.yml`のBundle IDを変更してから`xcodegen generate`を再実行してください。Node iOSフレームワークとライセンスは`Vendor`、転送スクリプトは`scripts`にあります。

## License

ComputeBridgeの独自コードは[MIT License](LICENSE)で公開しています。同梱する第三者コンポーネントには、それぞれのライセンスが適用されます。
