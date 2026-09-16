# sleepguard

[![English](https://img.shields.io/badge/English-555555?style=flat)](README.md) [![简体中文](https://img.shields.io/badge/%E7%AE%80%E4%BD%93%E4%B8%AD%E6%96%87-555555?style=flat)](README.zh-CN.md)

只读检查 macOS 无法自动睡眠的原因，提供 CLI 和菜单栏应用。sleepguard 读取 IOKit 电源断言，显示持有断言的进程、具有明确空闲睡眠阻塞语义的内核驱动，以及可读取的持有时长，同时检查常驻的 `SleepDisabled` 设置。

**开发原型，不是经过正式签名或公证的发行版。** 请从源码构建；菜单栏应用仅使用供本机验证的 ad-hoc 签名。

![sleepguard 输出示例](docs/images/example-output.png)

[演示视频](docs/demo.mp4)

## 构建与运行

需要 macOS 13+、Swift 6.1+ 工具链及 macOS SDK。

```bash
git clone https://github.com/zhuhroscar-tech/sleepguard.git
cd sleepguard
swift build -c release
./.build/release/sleepguard
```

菜单栏预览版与 CLI 共用 `SleepGuardCore`，可点击 Rescan 重新扫描：

```bash
bash scripts/build_app.sh
open dist/SleepGuard.app
```

应用没有 Developer ID 签名，也未经过 notarization。复制到其他 Mac 后可能被 Gatekeeper 阻止，不应当作可分发的正式版本。

## 理解结果

| 退出码 | 含义 |
| --- | --- |
| `1` | IOKit 读取失败 |
| `3` | 已确认存在阻塞项，即使其他检查不完整 |
| `2` | 扫描不完整或无法判断 |
| `0` | 必要检查完整，且在本工具覆盖范围内未发现阻塞项 |

未知断言类型、不一致的驱动数据和设置读取失败，不会被默认为无害。请先阅读警告再判断结论；扫描快照可能立即过时。

## 安全与范围

不终止或向进程发送信号，不创建或修改断言，不修改电源设置，不请求管理员权限，也不安装辅助程序。无网络请求和遥测，不读取用户文档。

工具不覆盖 `IODisplayWrangler` 一类电源层面的 “Idle sleep preventers”、计划的 dark wake 或 Power Nap。若同类型已有可读的持有者，汇总状态可能无法暴露另一个不可读的持有者。**报告正常不等于没有任何因素能让 Mac 保持唤醒**，请结合 `pmset -g assertions` 检查。

`SleepDisabled` 是通过公开 API 读取的未公开属性；内核 level 的解释也包含基于实测的假设。依据和边界见[分类与 API 参考](docs/REFERENCE.md)。

## 测试

```bash
swift run sleepguard-tests
RUN_LIVE_TESTS=1 swift run sleepguard-tests
```

第一条运行确定性测试，第二条额外启用实时 IOKit 检查。受限环境可能跳过部分检查，实时断言数量会随系统状态变化。

[MIT 许可证](LICENSE)
