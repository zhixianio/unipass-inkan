# Building and using UniPass Inkan Desktop

UniPass Inkan Desktop is the Mac half of UniPass Inkan. It builds Safe transactions, shows them to the offline iPhone signer as QR codes, reads the signatures back through the Mac's camera, shares them with Safe's transaction service, and puts fully signed transactions on chain. It is not trusted with any decision: the signer decodes and checks every request itself. The app holds no key to your Safe. Its only key belongs to a small **submitter account** that pays network fees and can't move anything in the Safe.

Like the signer, it is published as source only. You build it yourself. 中文摘要在文末。

## What you need

- A Mac running **macOS 26** or later, with a camera (the built-in one is fine).
- **Xcode 27** and **XcodeGen** (`brew install xcodegen`).
- An Apple developer team to sign with. The paid membership you need for the signer works. Signing without a team ("Sign to Run Locally") also builds, but every rebuild then looks like a different app to macOS: it asks for the camera again and may not find the pairing and submitter account saved by the previous build.
- **UniPass Inkan Signer** installed on your iPhone and set up offline: [apps/signer/BUILDING.md](../signer/BUILDING.md).
- A little ETH on your Safe's network for the submitter account, which pays the network fee when a transaction is executed.
- Optional: a free API key for Safe's transaction service from [developer.safe.global](https://developer.safe.global). Without one the app works, limited to 2 requests per second and 5,000 per month.

## Build

All commands run from `apps/coordinator`.

1. **Set your team and bundle ID.**

   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

   Edit `Config/Local.xcconfig`: `DEVELOPMENT_TEAM` is your 10-character Team ID (developer.apple.com → Account → Membership details), and `BUNDLE_ID_PREFIX` is a reverse-DNS prefix you own. The bundle ID becomes `<prefix>.coordinator`. `Local.xcconfig` is ignored by git. Don't change the Team ID or bundle ID once the submitter account holds funds: a different ID is a different app that can't read the old one's keychain. Withdraw the balance first.

2. **Generate the Xcode project and build.**

   ```bash
   xcodegen generate
   ```

   ```bash
   xcodebuild -project UniPassCoordinator.xcodeproj -scheme UniPassCoordinator -configuration Release -derivedDataPath build/DerivedData -allowProvisioningUpdates build
   ```

   Or open `UniPassCoordinator.xcodeproj` in Xcode and run the **UniPassCoordinator** scheme. A Release build contains no demo or developer code; use Debug only for the attack demo below.

3. **Open it.**

   ```bash
   open "build/DerivedData/Build/Products/Release/UniPass Inkan Desktop.app"
   ```

   You can copy the app to `/Applications`. If you run an outbound firewall such as LuLu, allow the app's connections the first time it asks; until then everything that needs the network keeps loading.

## First run

A short welcome flow walks you through setup. It appears only once.

1. **Pair your signer.** The Mac's camera turns on. On the iPhone, open UniPass Inkan Signer and tap **Pair with UniPass Inkan Desktop**, then hold the phone's screen up to the camera. The app checks on chain that the signer's address matches its public key, then saves the pairing. macOS asks for camera access the first time.
2. **Add a little ETH for network fees.** Send a small amount, for example 0.01 ETH, to the submitter account shown as an address and QR code. It has the same address on every network; fund it on the network you'll use. The balance updates by itself. You can skip this and top up later in Settings, but creating a Safe needs it.
3. **Create or add a Safe.**
   - **Create a Safe…**: give it a name, choose the network (Ethereum, Base or Sepolia) and its signers: your paired iPhone is always one; add other UniPass Inkan Signers by scanning their pairing codes, and hardware or other wallets by address. The threshold defaults to a majority, and a 1-of-N setup gets a clear warning. The review page shows the Safe's address (computed on this Mac before anything is sent), the signers, the threshold and the network fee. The submitter account sends one transaction that creates the Safe, plus the on-chain account of any signer that doesn't have one yet. When it lands, the app checks on chain that the Safe exists with exactly those signers and threshold, then adds it.
   - **Add an Existing Safe…**: enter its address and network. The app takes the Safe's creation parameters from Safe's transaction service, recomputes the address itself, and reads the Safe's current state on chain. It only accepts a Safe made by an official Safe factory whose signers and threshold haven't changed since creation, with no modules or guard, and with your paired signer as a signer: the offline signer can only trust what a Safe was created with. Otherwise it says why in one sentence.

After that, send some assets to the Safe (**Receive**) and register it on the signer: scan its registration code (**Settings › Signers & Safes › Register with the Signer…**), or just sign its first transaction, which registers it too.

You can have several Safes. Switch between them with the Safe card at the top of the sidebar; create or add more from there, from the File menu or in Settings.

## Everyday use

- **Send** (⌘N, or **Send** on Assets): choose an asset, a recipient (paste an address or pick one from the address book) and an amount, then review. The review page says in one sentence what will happen, shows the recipient's full address, the network, how many signatures are needed and the estimated network fee. Raw fields are under **Technical details**.
- **Sign:** **Sign with Signer** shows an animated QR code and turns on the camera. Scan it with the signer, check the transaction on the phone and confirm with Face ID, then hold the signer's screen up to the Mac. The app checks the signature and saves it to Safe's transaction service, where your other signers can see it.
- **Other signers** approve the same transaction in [Safe{Wallet}](https://app.safe.global) with their own wallets, or with their own UniPass Inkan Signer. The app picks their signatures up from the transaction service.
- **Execute:** when enough signatures are in, **Execute** shows the network fee (about and at most) and, after you click **Send**, sends the transaction from the submitter account, which pays the fee. The Safe's funds don't pay it. The submitter account refuses a node on the wrong chain and fees above its limits. **Other ways to execute** opens the transaction in Safe{Wallet} instead.
- **Receive** (⇧⌘R): the Safe's address as text and a QR code.
- **Activity** (⌘2): pending transactions (the sidebar shows how many) and history. Open one to see who signed, sign it with your signer, or execute it. Every transaction from the service is re-hashed on this Mac; one that doesn't match is marked and can't be signed or executed.
- **Address Book** (⌘3): names for addresses you send to. It stays on this Mac. The signer keeps its own address book, and the signer's is the one that counts when you sign.
- **Settings** (⌘,):
  - **General:** the network (it follows your Safe) and language (follows the system; set a per-app language in System Settings › General › Language & Region).
  - **Signers & Safes:** the paired signer, **Pair Again…**, **Unpair…**; your Safes with **Register with the Signer…** and remove (from this Mac only); **Create a Safe…** and **Add an Existing Safe…**.
  - **Submitter Account:** its address, QR code and balance, **Withdraw Balance…**, and **Use a New Account…**. There is no backup and no key export: if this Mac is lost, only the gas money in the account is lost.
  - **Advanced:** the transaction service API key, stored in this Mac's keychain.

Test networks are marked **Testnet** throughout the app.

## Attack demo

The attack demo shows what a tampered desktop app looks like: the screens show the transaction you entered, but a different request goes to the signer (a Bybit-style delegatecall, address poisoning, or a gas-refund drain), and the signer flags or refuses it. It exists only in **Debug** builds and only when you launch with a flag:

```bash
xcodebuild -project UniPassCoordinator.xcodeproj -scheme UniPassCoordinator -configuration Debug -derivedDataPath build/DerivedData -allowProvisioningUpdates build
```

```bash
open "build/DerivedData/Build/Products/Debug/UniPass Inkan Desktop.app" --args -InkanDemo YES
```

In Xcode, add `-InkanDemo YES` under the scheme's Run › Arguments. The main window looks exactly as usual. Choose **Window › Attack Demo Presenter** (⌃⌥⌘D) to open the presenter window, which has the scenario picker and shows what was really sent to the signer; it can sit on another screen while you record. Signatures made in demo mode are never saved. The step-by-step script is [docs/demo.md](../../docs/demo.md). A Release build contains none of this, which `scripts/check-release-no-attack-demo.sh` checks.

`-InkanDeveloper YES` adds a Developer menu with QR and transaction-service test pages and a simulated pairing for working without a phone.

## Troubleshooting

- **The welcome flow shows again, or the pairing is gone, after a rebuild:** the build wasn't signed with your team (check `Config/Local.xcconfig`), so macOS treats it as a different app. Rebuild with the team and the old data is back.
- **The camera stays black:** allow it in System Settings › Privacy & Security › Camera.
- **Everything keeps loading:** check the network, and allow the app in your firewall.

## Development

Code layout, conventions, tests and design notes: [DEVELOPMENT.md](DEVELOPMENT.md).

---

## 中文摘要

- **自己从源码构建**：macOS 26、Xcode 27、XcodeGen。复制 `Config/Local.xcconfig.example` 为 `Local.xcconfig`，填自己的 Team ID 和 Bundle ID 前缀，再 `xcodegen generate`、`xcodebuild … -configuration Release`。不用开发团队签名也能构建，但每次重新构建在 macOS 看来都是另一个 App，相机权限会再问、之前保存的配对和提交账户可能读不到。提交账户里有钱时不要改 Team ID 或 Bundle ID。
- **第一次打开**：欢迎引导依次是配对签名器（签名器上点「与 UniPass Inkan 桌面端配对」，屏幕对准 Mac 摄像头）、给提交账户充一点 ETH（创建 Safe 和执行交易的网络费都由它付，动不了 Safe 里的钱）、创建或添加 Safe。
- **创建 Safe**：填名字、网络（Ethereum / Base / Sepolia）、签名人（已配对的 iPhone 一定在内；另一台签名器扫配对码加入；硬件钱包和其他钱包按地址加入）、阈值（默认多数，1-of-N 有警告）。核对页显示发送前就在本机算好的 Safe 地址、签名人、阈值和网络费；提交账户发一笔交易创建 Safe（以及还没上链的签名器账户），上链后核对代码、签名人和阈值，再存进列表。
- **添加已有 Safe**：填地址和网络。从 Safe 交易服务取创建参数，本机重算地址，再读链上当前状态。只接受官方工厂创建、创建后签名人和阈值没改过、没有 module 和 guard、已配对的签名器在签名人里的 Safe；不满足时用一句话说明原因。添加前列出签名人和门限，确认后才加；其他签名人不经过你的签名器就能凑够门限时（例如 2-of-3 的 Inkan + Ledger + Trezor），会说明这一点，要勾选确认才能添加。
- 可以有多个 Safe，在侧边栏顶部的 Safe 卡片里切换。
- **日常**：发送（⌘N）→ 让签名器签名 → 摄像头收回签名、自动保存到 Safe 交易服务 → 其他签名人在 Safe{Wallet} 或自己的签名器上签 → 签齐后「执行」，先显示网络费"大约 / 最多"，点「发送」后由提交账户发出。活动（⌘2）看待处理和历史，地址簿（⌘3）只存在这台 Mac 上，设置（⌘,）分通用、签名器与 Safe、提交账户、高级四页。
- **攻击演示**：只在 Debug 构建里，带启动参数 `-InkanDemo YES` 运行；主窗口看起来和平时一样，「窗口 › Attack Demo Presenter」（⌃⌥⌘D）打开讲解窗口选场景。步骤见 docs/demo.md。`-InkanDeveloper YES` 打开开发者菜单。
- 开发说明见 [DEVELOPMENT.md](DEVELOPMENT.md)。
