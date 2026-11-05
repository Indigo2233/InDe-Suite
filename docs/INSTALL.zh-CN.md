# InDe-Suite 安装说明

当前提供 Windows x64 的 PixInsight Local Signing Edition，内含三个原生 Process、
InDeConv / InDeNoise / InDeStars 模型和完整推理环境。用户无需安装 Python 或编译源码。
三个 Process 封装在同一个模块中，一次模块安装即可使用全部功能。

Mac 用户请阅读独立的 [macOS 安装说明](INSTALL-macOS.zh-CN.md)，使用 `Install-macOS.command`。

## 推荐：双击安装向导

1. 打开 [v1.0.2-local Release](https://github.com/Indigo2233/InDe-Suite/releases/tag/v1.0.2-local)。
2. 下载小型安装入口 [InDe-1.0.2-setup-windows.zip](https://github.com/Indigo2233/InDe-Suite/releases/download/v1.0.2-local/InDe-1.0.2-setup-windows.zip)。
3. 将 ZIP **全部解压**到一个目录，双击其中的 `Install-Windows.cmd`。
4. 向导自动查找 PixInsight；自定义安装路径会弹出文件窗口，请选择 `bin` 目录里的 `PixInsight.exe`。
5. 首次安装，在签名身份问题中选择 `No`，按下方步骤生成并注册身份；已经完成的用户选择 `Yes`。
6. 选择自己的 `.xssk` 文件，保存图像并关闭所有 PixInsight 窗口。
7. 向导下载约 390 MiB 的完整包，校验 SHA-256、解压并校验包内文件。请保持安装窗口打开。
8. 在 PixInsight 弹出的签名密码窗口中亲自输入密钥密码。向导随后复制模块、签名和后端。
9. 按照“注册三个 Process”完成模块扫描和重启。

向导的提示使用英文，本页提供对应操作说明。向导会记住 PixInsight 路径和密钥文件路径，
保存在 `%LOCALAPPDATA%\InDeInstaller\preferences.json`，便于后续安装；密码只在 PixInsight 界面输入。
安装默认位于 `%LOCALAPPDATA%\Programs\InDe`，通常无需管理员权限。
启动器的执行策略设置仅作用于本次 PowerShell 进程。

## 首次生成 .xssk：按界面逐项填写

`.xssk` 是 PixInsight 生成的、受密码保护的签名密钥文件。每位用户在已激活自己许可证的
PixInsight 中生成并注册即可，无需申请 Certified PixInsight Developer 身份。
已有身份时请继续使用原来的文件，避免覆盖其他模块正在使用的密钥。

### 1. 准备保存位置

在自己的用户目录中新建 `PixInsightKeys` 文件夹。假设 Windows 用户名为 `Alice`，路径为：

```text
C:\Users\Alice\PixInsightKeys\local.xssk
```

`Alice` 请替换为实际用户名。当前 Windows 签名接口要求**完整路径只包含 ASCII 字符**，
建议使用英文字母、数字和常见英文符号。用户名含中文时，请自行选择其他 ASCII 路径的私有目录。
文件由用户保管，避免放进共享文件夹或提交到 GitHub。

### 2. 打开 SigningKeys

在 PixInsight 中打开 `Script > Development > SigningKeys`。
若菜单里找不到，使用 `Script > Execute Script File` 选择安装目录下的：

```text
C:\Program Files\PixInsight\src\scripts\SigningKeys\SigningKeys.js
```

自定义安装目录时替换前面的 `C:\Program Files\PixInsight`。
如果官方 SigningKeys 脚本提示 PixInsight 版本过旧，请先更新 PixInsight。

### 3. 填写生成选项

| 选项 | 操作 |
| --- | --- |
| `Generate Signing Keys` | 勾选 |
| `Local signing identity` | 勾选 |
| `Developer` | 此时禁用，留空 |
| `Export Signing Keys` | 保持未勾选 |
| `Output > Keys file` | 点击文件按钮，选择保存位置，文件名填 `local.xssk` |
| `Output > Password` | 自己设置并保存一个密码 |

密码至少 8 位，包含大写字母、小写字母，以及数字或标点；仅使用 ASCII 字符，不能含空格。
这是你为密钥新设置的密码。请在后续身份注册和模块签名时使用同一个密码。

点击 `Run`。确认控制台出现 `Signing keys file generated, local signing identity`，
并在选定目录看到 `local.xssk`。询问是否继续管理密钥时选择 `No`。

### 4. 注册本地签名身份

1. 打开 `Edit > Local Signing Identity...`。
2. `Keys file`：选择刚生成的 `local.xssk`。
3. `Password`：输入刚设置的密码。
4. 勾选 `Make the local signing identity persistent`，让身份在重启后继续有效。
5. 保持 `Remove the local signing identity` 未勾选，点击确认。

完成后返回安装向导，选择该文件。保存正在处理的图像并退出 PixInsight，然后继续安装。
密钥文件和密码均无需发送给项目作者或安装代理。

## 注册三个 Process

安装向导完成文件复制后可以启动 PixInsight；当前仍需要用户在官方界面完成首次模块注册。

1. 打开 `Process > Modules > Install Modules`。
2. 选择安装目录 `%LOCALAPPDATA%\Programs\InDe`。向导会显示展开后的实际路径。
3. 点击 `Search`，选择发现的 `InDe` 模块，点击 `Install`。
4. 重启 PixInsight。
5. 在 `Process > InDe` 中确认 `InDeConv`、`InDeStars`、`InDeNoise`。

随后通过 `Script > Execute Script File` 运行安装目录下的 `test\native-selftest.js`。
该脚本检查三个 Process 的注册和基本执行链路，结果写入 `%TEMP%\inde-native-selftest.json`，
成功时包含 `"ok": true`。再使用测试图像检查 View/Preview 和 Real-Time Preview。

## 离线安装与命令行

下载完整 `InDe-1.0.2-local-windows-x64.zip` 和 `SHA256SUMS-local.txt`，
校验 ZIP 后全部解压，双击其中同名 `Install-Windows.cmd`。完整包内的向导直接使用本地文件，
安装过程无需再下载模型。首次身份说明的在线链接可以用本地 `docs/INSTALL.zh-CN.md` 代替。

校验文件同时列出小型安装入口与完整包。Windows PowerShell 校验完整包示例：

```powershell
$name = 'InDe-1.0.2-local-windows-x64.zip'
$line = @(Get-Content .\SHA256SUMS-local.txt | Where-Object { $_ -match ('\s+' + [regex]::Escape($name) + '$') })
if ($line.Count -ne 1) { throw 'Missing or duplicate checksum' }
$expected = ($line[0] -split '\s+')[0]
if ((Get-FileHash -LiteralPath $name -Algorithm SHA256).Hash -ine $expected) { throw 'SHA-256 mismatch' }
```

已有签名身份时，可以在完整包目录执行：

```powershell
.\install-local.ps1 -KeysFile "$env:USERPROFILE\PixInsightKeys\local.xssk"
```

自定义位置示例：

```powershell
.\setup-windows.ps1 -PixInsightRoot 'D:\PixInsight' -Destination 'D:\PixInsightModules\InDe'
```

只校验完整包与目标目录，不弹窗、不下载、不签名、不安装：

```powershell
.\setup-windows.ps1 -CheckOnly -PackageDirectory (Get-Location).Path
```

更新时重新运行向导即可复用所选路径；模块 DLL 改变后需要重新签名。
下载内容保存在向导打印的临时目录中，失败后可以从已解压的完整包重试。

## macOS、Apple Silicon 与 Intel

macOS 提供 arm64 与 x86_64 两套模块和运行环境，安装流程详见
[macOS 安装与验证](INSTALL-macOS.zh-CN.md)。上述 PowerShell 入口适用于 Windows。

三个 ONNX 模型的权重文件可以跨平台共用。需要按目标平台准备的是原生 Process 模块、
Python、ONNX Runtime 及其本地依赖。

| PixInsight 实际运行架构 | 原生 Process 模块 | 后端运行环境 |
| --- | --- | --- |
| Windows x64 | x64 `.dll` | Windows x64 |
| macOS Apple Silicon 原生 | arm64 `.dylib` | macOS arm64 |
| macOS Intel | x86_64 `.dylib` | macOS x86_64 |
| Apple Silicon 上通过 Rosetta 运行 Intel 版 PixInsight | x86_64 `.dylib` | macOS x86_64 |

模块必须匹配 PixInsight 进程的架构。当前 Mac 安装包要求 macOS 14+，建议使用
PixInsight 1.9.5。默认使用 CPU，Core ML 为实验选项。CI 覆盖 CPU 推理及安装包检查；
PixInsight 界面、本地签名和 Real-Time Preview 需在装有许可证的 Mac 上进一步验证。

macOS 中创建和注册 `.xssk` 的 PixInsight 菜单流程与上文相同。

## 常见问题

- **PowerShell 执行策略提示**：推荐双击 `Install-Windows.cmd`；若组织策略仍阻止执行，请遵循组织的安装规则。
- **找不到 .xssk**：该文件通过 SigningKeys 的 `Generate Signing Keys` 生成；按本页首次配置步骤操作。
- **路径乱码或 No file(s) found**：确认密钥完整路径仅包含 ASCII 字符。
- **缺少 .xsgn 或签名失败**：确认已注册持久身份、密码正确、已关闭其他 PixInsight 窗口，然后重试。
- **包校验失败**：重新下载并完整解压同一 Release 的文件；同版本更新后也需要使用对应的新校验文件。
- **找不到 Process**：确认已在 Install Modules 中完成 Search 和 Install，然后重启。
- **找不到后端**：确认安装目录中包含 `InDeBackend\engine\models`、`InDeBackend\runtime` 和 `InDeBackend\tools`。
- **之前设置过 INDE_INSTALL_DIR**：该环境变量优先于模块同目录的后端；请确认它指向期望版本，修改后重启 PixInsight。

## Manage Repositories

当前 Local Signing Edition 采用用户本地签名流程。通过 PixInsight 更新系统面向其他许可证
分发模块，需要有效 CPD 签名及签名后的仓库描述文件；该发行方式尚未启用。
