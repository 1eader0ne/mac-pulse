# 轻诊 · Mac 异常占用诊断

使用与[人生计时器](https://github.com/1eader0ne/life-timer)相同的 **Swift + AppKit** 原生技术栈，通过 `swiftc` 构建。另有少量 C 代码连接 macOS 系统采样接口；无 Electron、后台服务器或外部依赖。

适用于 Apple Silicon Mac，最低 macOS 12。构建使用本机 ad hoc 签名，未使用 Developer ID 或进行 Apple 公证。

![轻诊界面示意（示例数据）](docs/preview.svg)

## 使用

源码构建后双击 `轻诊.app` 即可运行；也可使用 `package.sh` 生成 `轻诊-1.0.dmg`，将应用拖入 Applications。关闭最后一个窗口会退出工具并停止采样。

1. 每两秒采样一次 CPU、内存 RSS、内存压缩与交换、系统热压力以及虚拟网卡包速率。
2. 列表将一个应用及其辅助进程合并显示，按 CPU 降序排列；可搜索应用、进程名或 PID。
3. 默认 CPU 超过单核 80% 且持续 15 秒才标出“持续高占用”。阈值可选 30%、50%、80%、100%、150%。高占用是排查线索，不等于程序故障。
4. 点击应用查看明细。优先选择“正常退出应用”；应用可自行提示保存或拒绝退出。需要时另行点击“强制结束”，明确确认后执行。
5. 清理后重新采样，展示 CPU、RSS 变化和同应用残留进程数；应用自动重启时会说明尚有进程。
6. 可以暂停监测或导出本机 JSON 诊断报告。报告可能包含应用名、进程号和本机路径，请自行判断分享范围。

## 读数与保护边界

- **整机 CPU**：所有核心合计按 0–100% 显示。**应用 CPU**：100% 代表一个逻辑核心，多个核心可能超过 100%。
- 原生采样使用两个时刻的累计 CPU 时间差，包含 Apple Silicon 时间单位转换。受限的系统进程由系统 `/bin/ps` 提供只读平滑读数，以 `~` 标记，不能当成两秒瞬时值。
- RSS 为各进程驻留内存之和，共享页可能重复计算；它与活动监视器的“内存”口径不同。内存大不单独判定故障，不会通过占用内存再释放的方式“清内存”。
- 热压力由系统提供，**不是 CPU 温度**。本版不读取私有温度传感器，也不控制风扇。
- 网卡首次采样、计数重置或接口刚出现时等待下一次采样。TUN 包速率远高于物理网卡时只报告可疑失衡，不宣称已经证明网络循环。
- CPU、系统服务读数与真实负载可能瞬时变化，诊断不自动指认某个应用导致硬件发热。
- 只允许退出当前用户、已注册的非 Apple 应用。保护系统服务、其他用户、工具自身、命令行进程和身份不完整的进程。
- 每次清理前核对 PID、启动时间、用户、可执行路径、应用路径和 bundle ID。进程退出或 PID 被重用时拒绝对新进程操作。
- 不自动结束应用、不卸载软件、不删除文件、不更改代理或 DNS，不索取管理员权限。清理记录仅保存在当前会话内。
- 强制结束可能丢失未保存内容。正常退出超时后不会自动强制结束。

## 从源码构建

需要 Xcode Command Line Tools（本机已安装）。

```bash
cd native-app
bash build.sh
bash test.sh
bash package.sh
../轻诊.app/Contents/MacOS/MacPulse --probe
```

构建产物为上一层的 `轻诊.app`，中间文件默认写入 `.build`；可用环境变量 `MACPULSE_BUILD_DIR` 指定其他位置。测试仅创建和结束专门的 Fixture 应用及一个测试 CPU 进程，不会结束用户现有应用。

源码：`MonitorBridge.c/.h`（系统接口）、`Monitor.swift`（采样、聚合、判定与进程身份）、`Interface.swift`（界面与清理流程）、`main.swift`（入口及针对性测试）、`Icon.swift`（原生矢量图标绘制）。`package.sh` 生成并校验 DMG；它只删除自己创建的临时打包目录。

相关接口依据：[Apple NSRunningApplication.forceTerminate](https://developer.apple.com/documentation/appkit/nsrunningapplication/forceterminate())、[Apple XNU proc_info.h](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info.h)。
