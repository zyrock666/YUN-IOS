# YunX（云析）iOS —— 构建与安装说明

> 面向 **macOS 用户**。本工程是纯 Swift / SwiftUI，**没有任何第三方依赖**，不需要 CocoaPods / SPM 拉包。
>
> - Scheme：`YunX`
> - Target：`YunX`
> - Bundle ID：`com.yunx.ios`
> - 最低系统：iOS 16.0
> - 架构：**arm64 真机**（Apple Silicon 与 Intel Mac 都能构建，二者都只是在 Mac 侧编译，产物面向 iPhone 的 arm64）

---

## 一、前置条件

| 项目 | 要求 | 说明 |
| --- | --- | --- |
| 系统 | **macOS 13 (Ventura) 或更新** | 更老的系统装不了 Xcode 15 |
| 工具 | **Xcode 15 或更新** | App Store 免费下载，约 15 GB，装完还要等它安装组件 |
| 命令行工具 | Xcode 自带的 `xcodebuild` | 执行一次 `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` 即可 |
| 开发者账号 | **可选** | 只跑模拟器：不需要账号<br>真机：免费 Apple ID 即可（有限制，见下）<br>上架 App Store：**必须**付费 Apple Developer Program（688 元/年） |
| iPhone | iOS 16.0 及以上 | 装真机需要 |

### 关于免费 Apple ID 的限制（务必先看）

用免费 Apple ID 自签，**能装真机，但有硬限制**：

- 签名 **7 天后自动过期**，到期 App 打不开，得重新签一次（数据不会丢，只是要重装）；
- 同时最多只能装 **3 个**自签 App（全设备合计）；
- 每天最多重签/安装约 10 次；
- **不能用** `ad-hoc`、`app-store`、`enterprise` 这几种导出方式；
- 推送通知（Push）、应用内购买、iCloud 容器等依赖特殊 entitlement 的能力不可用。

如果只是自己用，这些限制一般可以接受；要长期使用/分发给别人，请购买付费开发者账号。

---

## 二、三条构建路径

### 路径 1：模拟器运行（推荐先走这条，**不需要任何账号**）

最快验证"代码能不能编译、界面长什么样"，完全绕开签名。

**方式 A —— 直接双击打开 Xcode（最省事）**

1. 打开 `YunX.xcodeproj`（若工程已生成 workspace，则打开 `.xcworkspace`）；
2. 顶部 Scheme 选 `YunX`，运行目标选任意模拟器（如 `iPhone 15`）；
3. 按 `⌘R`。

**方式 B —— 命令行**

```bash
# 先看看都有哪些可用模拟器
xcrun simctl list devices available

# 编译
xcodebuild -scheme YunX \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  build

# 编译 + 直接装到已启动的模拟器并运行（可选）
xcodebuild -scheme YunX -destination 'platform=iOS Simulator,name=iPhone 15' -derivedDataPath build/dd build
xcrun simctl boot "iPhone 15" 2>/dev/null || true
open -a Simulator
xcrun simctl install booted build/dd/Build/Products/Debug-iphonesimulator/YunX.app
xcrun simctl launch booted com.yunx.ios
```

> 模拟器版本默认是 `Debug` 配置，启动快；需要测性能就用 `-configuration Release`。

---

### 路径 2：真机自签（免费 Apple ID）

把 App 装到自己的 iPhone 上。**两条路，任选一条。**

#### 路线 A：在 Xcode 里点（推荐新手）

1. Xcode → `Settings` → `Accounts` → `+` → 添加你的 **Apple ID**，登录成功后左侧会出现 `(Personal Team)`；
2. 打开工程，左侧选中项目 → `TARGETS: YunX` → `Signing & Capabilities`；
3. 勾选 **Automatically manage signing**；
4. `Team` 下拉选你的 `(Personal Team)`；
5. **修改 Bundle Identifier**：把 `com.yunx.ios` 改成**全世界唯一**的值，例如 `com.yourname.yunx`。
   > 免费账号的 Bundle ID 是全局占用的，别人已经用过的 `com.yunx.ios` 你抢不到，不改一定报错。
6. iPhone 用数据线连上 Mac，解锁并点"信任此电脑"；
7. 顶部设备列表选中你的 iPhone，按 `⌘R` 编译运行；
8. 首次运行时 iPhone 会拒绝打开，去 **设置 → 通用 → VPN与设备管理 → 开发者 App** 里信任你的 Apple ID 证书（详见下方排查表）。

#### 路线 B：命令行 + `build-ipa.sh`

适合脚本化、批量打包。**前提是上面路线 A 的第 1 步和签名能力已经在 Xcode 里配好**（命令行不会帮你登录账号）。

```bash
# 先拿到你的 Team ID：Xcode → Settings → Accounts → 选中账号，右侧 Team 括号里那串 10 位
# 或者执行：security find-identity -v -p codesigning

chmod +x build-ipa.sh
./build-ipa.sh --team-id A1B2C3D4E5                 # 默认 development + Release
./build-ipa.sh --team-id A1B2C3D4E5 --configuration Debug
TEAM_ID=A1B2C3D4E5 ./build-ipa.sh --output ./dist    # 环境和参数都支持
./build-ipa.sh --team-id A1B2C3D4E5 --clean          # 先清理再打包
```

产物：`build/YunX-development.ipa`（脚本结束会打印**绝对路径**和大小）。

> **注意**：`development` 导出的 IPA 只能装到**已注册到你账号名下的设备**上，
> 所以第一次必须先按路线 A 连一次真机，让 Xcode 把这台设备注册进你的 Team。
>
> **免费账号只能用 `--export-method development`**。`ad-hoc` / `app-store` / `enterprise`
> 都需要付费账号。

安装到真机（任选一种）：

- Xcode → `Window` → `Devices and Simulators`，把 IPA 拖进去；或
- macOS 15+：`xcrun devicectl device install app --device <设备UDID> <路径>/YunX-development.ipa`

---

### 路径 3：无签名 IPA + 自签工具（Sideloadly / AltStore / TrollStore）

**完全不需要 Xcode 账号，甚至不需要登录 Apple ID 就能先把包做出来**；签名那一步交给第三方工具或手机端完成。
适合：手头只有 Linux/Windows 但要分发、想给别人装、或 Xcode 签名一直被 Provisioning 卡住。

```bash
chmod +x build-ipa-unsigned.sh
./build-ipa-unsigned.sh                    # 产物：build/YunX-unsigned.ipa
./build-ipa-unsigned.sh --configuration Debug --clean
./build-ipa-unsigned.sh --output ./dist
```

脚本做的事：`CODE_SIGNING_ALLOWED=NO` 编译出 `.app` → 手工建 `Payload/` → `zip -qry` 打包。
产物是一个 **未签名** 的 IPA，**无法直接安装到真机**，双击或用 Apple Configurator 安装都会失败。

接下来用自签工具：

| 工具 | 平台 | 说明 |
| --- | --- | --- |
| **Sideloadly**（<https://sideloadly.io>） | Windows / macOS | 最简单：连上 iPhone → 拖入 IPA → 填 Apple ID → Start。生成的签名同样 7 天有效 |
| **AltStore**（<https://altstore.io>） | Windows / macOS + iPhone | 需要在电脑上跑 AltServer，可 7 天自动续签，但每次续签仍要靠电脑 |
| **TrollStore** | 仅限部分 iOS 版本 | 免账号、永久签名；**前提是你的 iOS 版本在支持范围内**，不符合就只能用上面两个 |

自签完成后首次打开 App，若提示「**不受信任的开发者**」，去：
**设置 → 通用 → VPN与设备管理 → 开发者 App → 信任对应证书**。

---

## 三、常见报错排查表

| # | 报错信息（关键片段） | 原因 | 解决办法 |
| --- | --- | --- | --- |
| 1 | `Signing for "YunX" requires a development team.` | 工程里没选 Team | Xcode → Target → `Signing & Capabilities` → 选 `Team`；或命令行传 `--team-id <10位TeamID>` |
| 2 | `Provisioning profile "iOS Team Provisioning Profile" doesn't include ...` / `doesn't support ...` / `doesn't include signing certificate` | 设备没注册进描述文件，或描述文件与当前 Bundle ID / 证书不匹配 | ① 让 Xcode 自动管理签名（勾选 *Automatically manage signing*）；② iPhone 连一次 Mac 让 Xcode 重新生成 profile；③ 在 Xcode → `Settings → Accounts → Download Manual Profiles`；④ 改一个唯一的 Bundle ID；⑤ 删除 `~/Library/MobileDevice/Provisioning Profiles/` 里旧的文件重试 |
| 3 | `No signing certificate "iOS Development" found` / `No profiles for 'com.xxx' were found` | 这台 Mac 上没有安装 iOS 开发证书 | Xcode → `Settings → Accounts` → 选中账号 → `Manage Certificates…` → 左下 `+` → **Apple Development**；没有账号就先登录。**免费账号无法用 `ad-hoc`/`app-store` 导出** |
| 4 | 之前能用的 App，**7 天后**打开闪退 / 提示"开发者证书已过期" | 免费 Apple ID 的签名有效期就是 7 天 | 重新用 Xcode `⌘R` 或 Sideloadly 覆盖安装一次（**数据保留**）；想长期用就买付费账号，或改用 TrollStore（若版本支持） |
| 5 | 真机首次打开提示「**不受信任的开发者**」/ `Unable to Install "YunX"` | 签名证书还没被系统信任 | iPhone：**设置 → 通用 → VPN与设备管理 → 开发者 App → 点你的 Apple ID → 信任**；iOS 16+ 也可能在「设置 → 通用 → 关于本机 → 证书信任设置」 |
| 6 | `error: ExportOptions.plist ... missing` / `-exportOptionsPlist: file not found` / `Export failed` | 导出时没给（或给错了）导出配置 plist，或者手动跑命令时漏了参数 | 用 `./build-ipa.sh`（脚本会自动在临时目录里生成 `ExportOptions.plist`，用完即删）；手动执行时必须有 `-exportOptionsPlist <文件>`。生成的 plist 至少要有 `method`（`app-store`/`ad-hoc`/`development`/`enterprise`）和 `signingStyle` |
| 7 | `xcodebuild: error: command not found` / `requires Xcode, but active developer directory is ...` | 没装 Xcode，或命令行工具指向 CommandLineTools | `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` 后执行 `sudo xcodebuild -license accept` |
| 8 | `The requested device could not be found` / 模拟器 `iPhone 15` 不存在 | 模拟器没装或名字对不上 | `xcrun simctl list devices available` 查真实名字；或在 Xcode → `Settings → Platforms` 里下载对应 iOS 模拟器 |
| 9 | `Command CodeSign failed ... resource fork, Finder information, or similar detritus not allowed` | 工程目录里有扩展属性（常见于从网盘/压缩包拷贝的工程） | `xattr -cr /path/to/YunX-iOS`，然后重新构建 |
| 10 | `No such module 'SwiftUI'` / `iOS 16.0 is required` | 用老 Xcode 打开了工程 | 升级到 Xcode 15+，并确认 Deployment Target 为 iOS 16.0 |
| 11 | 在 Linux / Windows 上运行脚本，提示「未找到 xcodebuild」 | 打包必须用 macOS | 换 Mac；只是想产出 IPA 文件的话，可以在 Mac 上跑 `./build-ipa-unsigned.sh` 再拷走 |
| 12 | 未签名 IPA 安装失败：`ApplicationVerificationFailed` / 直接报签名错误 | 未签名 IPA 本来就不能直接装 | 用 Sideloadly / AltStore / TrollStore 自签后再装，见「路径 3」 |

**万能第一步**：Xcode 里 `⌘⇧K`（Clean Build Folder）→ `⇧⌘⌥K` 之后重新构建；
命令行则 `./build-ipa.sh --clean`。大多数签名类的玄学问题清一次就好了。

---

## 四、注意事项

1. **架构**：工程依赖 **arm64 真机**（`iphoneos` arm64）。Apple Silicon（M 系列）和 Intel Mac 都能构建，编出来都是给 iPhone 的 arm64 包；
   Intel Mac 上跑模拟器需要 Rosetta 的 x86_64 模拟器运行时，Xcode 15 会提示下载。
2. **必须用 iOS 16.0+ 的真机**。低于 iOS 16 的设备装不上。
3. **没有 Apple 开发者账号就无法上架 App Store**。App Store 分发需要付费的 Apple Developer Program 会员资格（个人 688 元/年），
   免费 Apple ID 只能本机自签调试，不能提交审核、不能用 TestFlight。
4. **不要提交个性化配置**：`build/`、`*.ipa`、`*.xcarchive`、`DerivedData/` 都已属于构建产物，不要提交到版本库。
   `.gitignore` 里建议包含：
   ```
   build/
   DerivedData/
   *.ipa
   *.xcarchive
   *.dSYM.zip
   .DS_Store
   xcuserdata/
   ```
5. **脚本兼容性**：两个 `.sh` 都为 **macOS 自带的 bash 3.2** 编写，不使用 `declare -A`、`${var^^}`、`mapfile` 等 bash 4+ 特性，
   直接 `./build-ipa.sh` 即可，无需 `brew install bash`。

---

## 五、许可证

本项目采用 **AGPL-3.0**（GNU Affero General Public License v3.0）。

- 你可以自由使用、修改、分发；
- **二次分发（包括修改后重新打包成 IPA 分发、或作为网络服务提供给他人使用）必须以同样的 AGPL-3.0 协议开源**，
  并向接收者提供完整的对应源代码；
- 分发时必须保留原版权与许可证声明。

完整条款见仓库根目录的 `LICENSE` 文件，或 <https://www.gnu.org/licenses/agpl-3.0.html>。
