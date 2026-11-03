# macOS 适配验证记录

迁移前的双架构验证于 2026-10-29（UTC+8）完成。本仓库首次推送后需要在
GitHub Actions 中重新运行 `macOS packages`，确认改名后的源码与打包流程。

| 验证项目 | Apple Silicon arm64 | Intel x86_64 |
| --- | --- | --- |
| PCL 2.10.8 原生模块编译 | 通过 | 通过 |
| Mach-O 架构及 Apple ad-hoc 签名 | 通过 | 通过 |
| 动态库加载及导出入口检查 | 通过 | 通过 |
| CPU 推理：InDeConv、InDeStars、InDeNoise | 通过 | 通过 |
| 同一 worker 连续执行 6 个请求 | 通过 | 通过 |
| 重复请求结果一致性、像素尺寸与有限值检查 | 通过 | 通过 |
| 去星附加输出、降噪颜色及频率分离 | 通过 | 通过 |
| 搬迁至含空格和中文路径后的依赖加载 | 通过 | 通过 |
| 安装器只读预检、逐文件 SHA-256 | 通过 | 通过 |
| 文件被修改后拒绝安装 | 通过 | 通过 |

依赖版本：Python 3.12.16、ONNX Runtime 1.23.2、NumPy 2.2.6、OpenCV 4.12.0.88。
两种架构的运行环境均报告包含 `CoreMLExecutionProvider`；实际模型测试使用 CPU。
Core ML GPU/ANE 的模型分区、输出误差和硬件性能尚未验收，界面保留实验选项，默认 Auto 使用 CPU。

安装器预检使用带真实 Mach-O 可执行文件的测试 app 目录；未运行 PixInsight 签名或 GUI。
以下项目需要安装有许可证的 Mac 完成实机验证：

- PixInsight 通过 `.xssk` 创建本地模块签名。
- Install Modules 注册后，三个 Process 可以执行。
- Real-Time Preview 可以切换原图与处理结果，参数更新和取消行为正常。
- Core ML 在具体 Apple Silicon 或 Intel 硬件上的正确性和性能。

Windows 回归验证：原生 DLL 编译、四项推理设备选择测试、三个模型六次连续管道请求以及
Windows PowerShell 5.1 安装器测试均通过。本次发布仅新增 Mac 资产。

复验方法参见 [macOS 安装说明](INSTALL-macOS.zh-CN.md)。
