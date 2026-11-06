# macOS 安装与验证

支持 macOS 14 及以上，使用与 PixInsight 1.9.5 配套的 PCL 2.10.8 构建。
Apple Silicon 提供 arm64 包，Intel 提供 x86_64 包。最低 PixInsight 兼容性以实际模块加载结果为准，建议使用最新 1.9.5。

两个包共用 InDeConv、InDeNoise、InDeStars 的 ONNX 权重；每个包包含对应架构的
`InDe-pxm.dylib`、Python、ONNX Runtime、NumPy 和 OpenCV。
三个 Process 安装在同一个模块中，无需另装 Python、Homebrew 或模型。

## 推荐安装方法

1. 在 [v1.0.2-local Release](https://github.com/Indigo2233/InDe-Suite/releases/tag/v1.0.2-local)
   下载 `InDe-1.0.2-setup-macos.zip`，解压后双击 `Install-macOS.command`。
2. 首次使用先在 PixInsight 中创建并注册本地签名身份，具体步骤见下一节。
3. 保存图像并退出 PixInsight。安装器查找 PixInsight.app，根据其可执行文件架构下载完整包，
   验证 SHA-256 和包内文件，随后让您选择 `.xssk`。
4. 在 PixInsight 弹出的官方密码窗口中输入密码。安装器不会读取或保存密码及密钥内容。
5. 安装完成后启动 PixInsight，打开 `Process > Modules > Install Modules`，选择：

   ```text
   ~/Library/Application Support/InDe
   ```

   文件选择窗口可按 `Command + Shift + G` 输入路径。点击 `Search` 和 `Install`，然后重启。
6. 在 `Process > InDe` 中打开 `InDeConv`、`InDeStars`、`InDeNoise`。

如果 Finder 阻止首次打开 `.command`，右键选择打开；必要时到系统设置 > 隐私与安全性中
允许打开刚下载的安装入口。完整包提供 Apple ad-hoc 代码签名和用户自己的 PixInsight 本地签名，
尚未经过 Apple Developer ID 公证。安装器仅清除经校验的 InDe 暂存文件的下载隔离属性。

## 首次创建本地签名身份

1. 启动 PixInsight，打开 `Script > Development > SigningKeys`。
2. 勾选 `Generate Signing Keys` 和 `Local signing identity`。
3. 在 `Output` 指定您私有目录中的 `.xssk` 文件，例如：
   `/Users/yourname/PixInsightKeys/local.xssk`。
4. 设置满足界面要求的密码，点击 `Run`。密码至少 8 位，使用 ASCII 字符，包含大写字母、
   小写字母及数字或标点，不含空格。
5. 打开 `Edit > Local Signing Identity`，选择刚生成的文件，输入密码，勾选
   `Make the local signing identity persistent` 后确认。
6. 保管好密钥和密码；已经注册过本地身份的用户可以复用现有身份。

## 离线包与架构

| PixInsight 运行架构 | 完整安装包 |
| --- | --- |
| Apple Silicon 原生 arm64 | `InDe-1.0.2-local-macos-arm64.tar.gz` |
| Intel x86_64，或通过 Rosetta 运行的 Intel PixInsight | `InDe-1.0.2-local-macos-x86_64.tar.gz` |

下载同架构的 `SHA256SUMS-macos-arm64.txt` 或 `SHA256SUMS-macos-x86_64.txt`，
在下载目录中运行，例如：

```bash
shasum -a 256 -c SHA256SUMS-macos-arm64.txt
```

确认 `OK` 后双击解压 `.tar.gz`，再双击包内的 `Install-macOS.command`。
完整包安装期间无需联网。架构以 PixInsight 为准；Universal PixInsight 默认选择安装器当前运行架构，
若用户主动以 Rosetta 运行 PixInsight，应通过 `--arch x86_64` 明确指定。

高级参数示例：

```bash
bash setup-macos.sh \
  --pixinsight-app /Applications/PixInsight/PixInsight.app \
  --keys-file "$HOME/PixInsightKeys/local.xssk" \
  --destination "$HOME/Library/Application Support/InDe"
```

只读检查完整包：

```bash
bash setup-macos.sh --check-only \
  --package-directory /path/to/InDe-1.0.2-local-macos-arm64 \
  --pixinsight-app /Applications/PixInsight/PixInsight.app
```

安装器在签名成功后替换安装目录，旧版本保存在相邻的 `.backup-日期时间` 目录。
更新后需要重新签名；保留同一安装路径通常可以延续现有模块注册。

## 推理与实时预览

- `Auto (CPU)` 和 `CPU` 使用 CPU 推理，默认保持这一配置。
- `Core ML (macOS, experimental)` 请求 Core ML Execution Provider，支持的子图可以使用
  Apple GPU/Neural Engine，其他节点由 CPU 执行。首次编译可能较慢，性能需要具体机器测量。
- `DirectML` 参数保留编号供 Windows Process Icon 兼容，Mac 应选择其他选项。
- 原生 Real-Time Preview、显示原图、参数更新和会话缓存沿用同一套原生代码。

CI 在两种架构的 Mac 上编译模块并运行三个模型的 CPU 推理、重复调用、管道输出及安装包检查。
CI 没有 PixInsight 许可证，实际 PixInsight 本地签名、模块注册和 Real-Time Preview
尚需用户在装有许可证的 Mac 上验证。Core ML 硬件加速尚未作为默认路径验收。
已完成的具体测试及构建记录见 [macOS 适配验证记录](MACOS-VALIDATION.md)。

安装后在 PixInsight 中执行 `Script > Execute Script File`，选择安装目录中的
`test/native-selftest.js`，确认控制台测试成功。随后在非关键图像上检查 Real-Time Preview：
能切换原图和处理结果、修改参数后能更新、再次更新能够复用会话。

遇到加载错误时保留 PixInsight 控制台原文、macOS 版本、PixInsight 版本以及所选架构。
更换 Process 包前退出 PixInsight。不要删除图像、Process Icon 或个人密钥。

## 开发构建

需要 Xcode、CMake、Git 和用于打包的 Python 3.12+。构建脚本固定官方 PCL 源码提交。

```bash
bash build-macos.sh
python3 tools/package-macos.py --model-distribution-authorized
```

可运行仓库 Actions 中的 `macOS packages` 工作流生成两套安装包。模型来自现有、固定
SHA-256 的授权 Release。CI 只生成可下载构建产物，发布者检查成功后再上传 Release。
发布时运行 `Publish verified macOS packages` 工作流，填写成功的构建 run ID 并确认公开发布。
发布工作流校验构建来自 main 且已成功、校验两个归档，自动生成小型安装入口，再上传六个 Mac 资产。
Windows 资产使用独立名称并予以保留。

This product is based on software from the PixInsight project, developed by
Pleiades Astrophoto and its contributors (https://pixinsight.com/).
