# 怎么打包出 IPA

本机是 Linux，**iOS 构建强制要求 macOS + Xcode**（苹果的硬限制，无法绕过）。
所以 IPA 通过 **GitHub Actions 的免费 macOS runner** 产出。

排过一遍后本机走不通的路，写在这里免得白试：

| 方案 | 结论 |
|---|---|
| 本机直接编译 | ❌ 无 Swift / Xcode 工具链 |
| Docker + macOS 镜像（docker-OSX） | ❌ 本机 CPU 是 Pentium N3700（Braswell），**不支持 AVX2**，macOS 起不来 |
| 装 Linux 版 Swift 编译 | ❌ Linux Swift 没有 SwiftUI / UIKit / CommonCrypto，编译器直接不认识 |
| **GitHub Actions macOS runner** | ✅ **推荐，本文方案** |

---

## 一、上传到 GitHub

```bash
cd YunX-iOS
git init
git add .
git commit -m "云析 iOS：11 平台移植"
git branch -M main
git remote add origin https://github.com/<你的用户名>/YunX-iOS.git
git push -u origin main
```

`.github/workflows/build-ipa.yml` 会自动被识别。

## 二、开权限

仓库 **Settings → Actions → General**：

1. **Actions permissions** 选 `Allow all actions and reusable workflows`
2. 页面底部 **Workflow permissions** 选 **Read and write permissions**
   （只有勾了这项，推 tag 时才能把 IPA 挂到 Release）

## 三、触发构建

**方式 A：手动**
Actions 页 → 左侧 `Build iOS IPA` → 右侧 `Run workflow` → 选 `Release` → 运行

**方式 B：推 tag（推荐，会顺便发 Release）**
```bash
git tag v1.0.0
git push origin v1.0.0
```

**方式 C：推代码**
推到 `main` 自动构建，但不发 Release。

## 四、拿 IPA

构建约 **3~6 分钟**。跑完后：

- **普通构建**：在该次 run 页面底部 → `Artifacts` → 下载 `YunX-unsigned-ipa`
- **推 tag 构建**：直接去仓库 `Releases` 页下载 `YunX-unsigned-v1.0.0.ipa`

产物名形如 `YunX-unsigned-a1b2c3d4.ipa`（带 short SHA）。

## 五、装到 iPhone

产出的 IPA **没有签名**，不能直接装，必须用自签工具：

| 工具 | 平台 | 说明 |
|---|---|---|
| **Sideloadly** | Windows / macOS | 最简单，拖 IPA 进去填 Apple ID 即可 |
| **AltStore** | Windows / macOS + iPhone | 可自动续签，7 天到期自动重签 |
| **TrollStore** | 仅特定 iOS 版本 | 免账号、永久签名 |

**Sideloadly 步骤**：
1. 下载安装 → 连 iPhone（需装 iTunes 或 Apple Devices 驱动）
2. 把 IPA 拖进窗口 → 填 Apple ID → `Start`
3. 首次打开若提示「不受信任的开发者」→
   iPhone 设置 → 通用 → VPN与设备管理 → 开发者 App → 信任

> ⚠️ 免费 Apple ID 签名的 **有效期 7 天**，且最多同时签 3 个 App。到期 App 会打不开，需重新签。
> 想长期使用需要付费开发者账号（99 美元/年）。

---

## 六、构建失败怎么查

workflow 失败时会自动上传 `build-log` artifact，里面是完整的 xcodebuild 输出。

### 已内置的预检查

workflow 在编译前会先跑两道检查，把最常见的两类问题提前拦下：

1. **scheme 存在性** —— 纯手写 pbxproj 默认没有 shared scheme，
   `-scheme YunX` 会报 `scheme not found`。
   已提供 `YunX.xcodeproj/xcshareddata/xcschemes/YunX.xcscheme`。
2. **源文件登记一致性** —— pbxproj 里登记的 Swift 文件数必须等于磁盘上的数量。
   不一致说明新增文件后忘了重跑生成器，会在编译时报 `cannot find type X in scope`。

### 常见报错对照

| 报错 | 原因 | 修法 |
|---|---|---|
| `xcodebuild: error: The project does not contain a scheme named "YunX"` | scheme 没提交 | 确认 `.xcodeproj/xcshareddata/xcschemes/` 在 git 里 |
| `cannot find type 'XxxResolver' in scope` | pbxproj 漏登记文件 | `python3 tools/gen_pbxproj.py .` 后重新提交 |
| `No such module 'CommonCrypto'` | 139 的平台依赖 | 换 Xcode 15+；或在 `C139Resolver.swift` 里手工声明 `CCCrypt` |
| `Signing for "YunX" requires a development team` | 签名参数没生效 | 确认 `CODE_SIGNING_ALLOWED=NO` 有传进去 |
| `No such module 'SwiftUI'` | SDK 选错 | 必须 `-sdk iphoneos`，不能是 macosx |
| `The operation couldn't be completed. Unable to locate a Java Runtime` | 无关告警 | 忽略，只是某些工具的提示 |
| 编译成功但 `找不到编译产物 YunX.app` | 产物落在 DerivedData 而非 SYMROOT | 脚本已同时查两处；若仍失败看日志里的目录结构诊断 |

### 本机自测（有 Mac 时）

```bash
./build-ipa-unsigned.sh          # 无签名 IPA
./build-ipa.sh --team-id ABC123  # 签名 IPA（需要证书）
```

---

## 七、如果你想在本地 Mac 上打签名版

GitHub Actions **不能**替你签名 —— 证书和私钥在你的 Apple ID 里，CI 上拿不到。
需要签名版时：

```bash
# 1. 用 Xcode 打开，Signing & Capabilities 里选你的 Team
open YunX.xcodeproj

# 2. 或命令行（先确认证书已装进钥匙串）
./build-ipa.sh --team-id <你的TeamID> --export-method development
```

详见 [BUILD.md](BUILD.md)。
