# Building UniPass Inkan Signer for your own iPhone

UniPass Inkan is published as source only: there is no App Store or TestFlight build, and we do not ship signed installers. You build the signer yourself, sign it with your own Apple developer account, and install it on an iPhone that then stays offline.

中文摘要在文末。

## What you need

- A Mac with **Xcode** (we build with Xcode 27.0) and **XcodeGen** (`brew install xcodegen`).
- An iPhone with iOS 26 or later, a **device passcode**, and **Face ID** set up. We test on an iPhone 15 Pro. Without a passcode the signing key cannot be created; this is intended.
- A **paid Apple Developer Program membership**. See the next section.

## Why a paid developer account

A free account (Xcode "Personal Team") can install apps on your phone, but Apple says: "Provisioning profiles that enable apps to be installed on a device will expire 7 days from issuance. You'll need to rebuild and reinstall your app to your device after expiration." ([Compare memberships](https://developer.apple.com/support/compare-memberships/)) A signer that has to be reconnected to a Mac, and brought online, every week defeats the point of keeping it offline.

With a paid membership the development provisioning profile Xcode creates is valid for a year (the profile we build with has `TimeToLive` 365; Apple's help pages do not state this figure).

## Know this before the phone goes offline

1. **The first launch needs the internet.** "New Apple Developer Program memberships created after June 6, 2021, require development- and ad-hoc-signed apps for iOS … to check in with the PPQ service when the app is first launched. … If the device can't successfully make a connection, the app may not launch." ([Provisioning profile updates](https://developer.apple.com/help/account/provisioning-profiles/provisioning-profile-updates)) On our iPhone, an app installed while the phone was offline showed "Unable to Verify App" until we turned on Wi-Fi and **tapped the icon on the phone once**; launching it from the Mac with `devicectl` did not count. This applies again after every reinstall.
2. **Offline for more than 30 days is not guaranteed.** The same page says: "If your app needs to run offline for more than 30 days after first launch, submit a request for extended offline provisioning profile validity support. A request form will be coming soon." We have not measured what happens after 30 days. Until then, plan to bring the phone online and open the app once a month.
3. **Reinstall before the profile expires.** About a year after you build, install a fresh build while the phone is online, open it once, then go offline again. Installing over the existing app keeps the signing key and your registered Safes.
4. **Never change the Team ID or bundle ID after creating a key.** The signing key lives in the iPhone's Secure Enclave and the Keychain entry that refers to it belongs to your Team ID + bundle ID. A build with a different Team ID or bundle ID is a different app and cannot reach the old key. If that happens, the other signers of your Safe have to replace this iPhone as a signer.

## The Mac you build on

The Mac that builds and installs the signer can also install a modified signer over it with your Team ID, and a phone that trusts it can be changed from it while connected. So if that Mac is compromised, treat the signer as compromised too. Preferably use a different Mac from the one that runs UniPass Inkan Desktop, and once the signer is installed, remove the phone's trust in that Mac (Settings → General → Transfer or Reset iPhone → Reset → Reset Location & Privacy; this forgets every trusted computer).

## Build and install

All commands run from `apps/signer`.

1. **Set your team and bundle ID.**

   ```bash
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

   Edit `Config/Local.xcconfig`: `DEVELOPMENT_TEAM` is your 10-character Team ID (developer.apple.com → Account → Membership details), `BUNDLE_ID_PREFIX` is a reverse-DNS prefix you own. The app's bundle ID becomes `<prefix>.signer`. The default prefix in `Config/Signer.xcconfig` is UniPass's own App ID, which is registered to our team and will not sign for you. `Local.xcconfig` is ignored by git.

2. **Generate the Xcode project.**

   ```bash
   xcodegen generate
   ```

3. **Check that the build contains no network code**. The script builds the Release configuration unsigned and scans the binary for network frameworks and symbols. Run it before step 4: it replaces the build products.

   ```bash
   ./scripts/check-no-network.sh
   ```

4. **Turn on Developer Mode on the iPhone** (Settings → Privacy & Security → Developer Mode, then restart). iOS requires it for development-signed apps.

5. **Build the Release configuration.** Release leaves out every debug-only switch (for example "ignore network check" and the demo scenarios), so the offline requirement you test is the real one. Connect the iPhone with a cable and unlock it. Building for the connected device the first time lets Xcode register it with your account:

   ```bash
   xcrun devicectl list devices
   ```

   ```bash
   xcodebuild -project Signer.xcodeproj -scheme Signer -configuration Release -destination 'id=<UDID>' -derivedDataPath build/DerivedData -allowProvisioningUpdates build
   ```

   You can also do this in Xcode: open `Signer.xcodeproj`, Product → Scheme → Edit Scheme → Run → Build Configuration: Release, choose your iPhone, Run.

   Optional: confirm the debug switches are gone. The count should be 0.

   ```bash
   strings -a build/DerivedData/Build/Products/Release-iphoneos/Signer.app/Signer | grep -c -e debugIgnoreNetwork -e demoScenario -e InkanDemo
   ```

6. **Install.**

   ```bash
   xcrun devicectl device install app --device <UDID> build/DerivedData/Build/Products/Release-iphoneos/Signer.app
   ```

## First run

1. **While the phone is still online**, tap the **Inkan** icon once so iOS can verify your developer certificate. The home screen says "Online: cannot sign"; that is expected.
2. In **Settings** (not Control Center), turn on **Airplane Mode**, then turn off **Wi-Fi** and **Bluetooth**, and **unplug the cable**. A connected cable also counts as a network connection. Use Settings because turning Wi-Fi or Bluetooth off in Control Center only disconnects until the next day or a restart, while "To completely disable Wi-Fi and Bluetooth for all networks and devices" you turn them off in Settings ([Apple](https://support.apple.com/en-us/102412)). Airplane Mode alone "turns off all radios except for Bluetooth", and if you turned Wi-Fi or Bluetooth back on while in Airplane Mode, the iPhone remembers that next time ([Apple](https://support.apple.com/en-us/108785)). The signer does not read Bluetooth status (that would need the CoreBluetooth framework, and the signer links no communication framework), so check Bluetooth yourself.
3. Open Inkan again. The home screen should say **"Offline: ready to sign"**.
4. Tap **Get started**, choose the Face ID setting, then tap **Create signing key**. Nothing is preselected or recommended; the setting cannot be changed later, and a different setting means a new key.
   - **Only the faces enrolled now**: safer, since nobody can sign by adding their own face; but any Face ID change disables the key for good, so it is easier to lose.
   - **Any enrolled face**: keeps working when Face ID changes; but anyone who knows your passcode can add their face and sign.

   Either way, turn on **Stolen Device Protection** (Settings → Face ID & Passcode).
5. **Pair with UniPass Inkan Desktop**: the signer shows a QR code with this iPhone's signer address; the desktop app scans it and adds that address as a signer when it creates your Safe. The signer address belongs to a signer contract, not a wallet: **never send funds to it**, they cannot be recovered. Receive funds at your Safe's address.
6. Add your Safe: scan a Safe code from the desktop app, or scan the first signing request, which can carry the Safe's details. The signer checks the Safe address offline and only accepts a Safe that has this iPhone as a signer.

The phone stays offline from now on. Everything travels by QR code.

## Updating

Connect the phone, turn on Wi-Fi, build and install as above, tap the icon once, then go offline again as in step 2 of First run (in Settings: Airplane Mode on, Wi-Fi and Bluetooth off) and unplug. The key and your Safes are kept, as long as the Team ID and bundle ID are unchanged.

## For developers: a second, separate copy

To try the whole flow from scratch (a new key, a new Safe) without touching the copy you already use, build the same source under a different bundle ID. Pass the prefix on the command line instead of editing `Local.xcconfig`, and use a separate DerivedData folder:

```bash
xcodebuild -project Signer.xcodeproj -scheme Signer -configuration Release -destination 'generic/platform=iOS' -derivedDataPath build/DemoDerivedData -allowProvisioningUpdates BUNDLE_ID_PREFIX=<prefix>.demo build
```

```bash
xcrun devicectl device install app --device <UDID> build/DemoDerivedData/Build/Products/Release-iphoneos/Signer.app
```

The bundle ID becomes `<prefix>.demo.signer`; the home-screen name is still **Inkan**, so the two icons look the same (put them on different pages). The copies share nothing:

- The Keychain entry holding the key is named after the bundle ID and sits in the app's own access group (`<Team ID>.<bundle ID>`); the app requests no shared access groups.
- The Secure Enclave key has no application tag; the only handle to it is the encrypted blob in that Keychain entry.
- My Safes, the address book and settings live in the app's own sandbox (Application Support, UserDefaults); there are no app groups.

Installing the second copy does not remove or change the first. Delete it like any other app when you are done.

---

## 中文摘要

- **只能自己从源码构建**，必须用**付费开发者账号**：免费账号签的 App 7 天就过期，过期后要连 Mac 重新签名安装，和长期离线冲突。付费账号的描述文件有效期一年（我们构建出的描述文件 `TimeToLive` 是 365 天，苹果文档里没写这个数）。
- **首次启动要联网**：2021-06-06 之后开通的会员资格，开发签名的 App 首次启动要连苹果的 PPQ 服务校验。所以装好后先在联网状态下在手机上点开一次，再断网。每次重新安装都要再来一遍。
- **离线超过 30 天没有保证**：苹果说离线超过 30 天要另外申请，申请表还没上线。还没有实测过，建议每月联网打开一次。
- **一年内重新安装**：描述文件过期前，联网覆盖安装一次。覆盖安装不会丢失密钥和已加入的 Safe。
- **构建用的电脑**：构建、安装签名器的那台电脑能用你的 Team ID 覆盖安装一个改过的签名器，连着线时也能改动手机，所以它被攻破就等于签名器被攻破。最好不要用运行桌面端的那台；装完在 设置 › 通用 › 传输或还原 iPhone › 还原 › 还原位置与隐私 里撤销对它的信任（会忘掉所有信任过的电脑）。
- **生成密钥后不要改 Team ID 或 Bundle ID**，否则新 App 读不到旧密钥，只能由 Safe 的其他签名人把这台签名器换掉。
- **签名人地址不能收款**：它是签名合约的地址，不是钱包，转进去的资产永久取不回。收款请用 Safe 地址。
- **开发者：装第二份独立的签名器**（从零演示完整流程用）：构建时在命令行加 `BUNDLE_ID_PREFIX=<前缀>.demo`、用单独的 `-derivedDataPath build/DemoDerivedData`，不用改 `Local.xcconfig`。两份 App 的密钥、我的 Safe、地址簿完全隔离，装第二份不影响第一份。
- 步骤：复制 `Config/Local.xcconfig.example` 为 `Config/Local.xcconfig`，填 Team ID 和 Bundle ID 前缀 → `xcodegen generate` → `./scripts/check-no-network.sh` 核对没有网络代码 → 打开手机的开发者模式 → 用 **Release** 配置构建并安装 → 联网点开一次 → 在**设置**里打开飞行模式、关掉 Wi-Fi 和蓝牙，拔线（不要用控制中心：那里的开关只断开到第二天，之后会自动恢复；飞行模式也不会关蓝牙）→ 首页显示"已离线，可以签名" → 生成密钥并选择 Face ID 设置 → 和 UniPass Inkan 桌面端配对。
