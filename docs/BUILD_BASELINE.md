# Build Baseline — RemoteDesktop 构建基线

> 建立时间: 2026-06-25 by Claude (T-230)
> 最新 commit: `40a7ef8`

## 当前基线

| 项目 | 值 |
|------|-----|
| 最新 commit | `40a7ef8` |
| 分支 | master |
| freerdp 子模块 | dirty (已知, 不重置) |
| 其他工作区状态 | clean |

## 构建命令 (官方)

```powershell
$env:DEVECO_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
$env:OHOS_SDK_HOME='C:\Program Files\Huawei\DevEco Studio\sdk'
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

## 工具链版本

| 工具 | 版本/路径 |
|------|-----------|
| DevEco Studio | 26.0 (`C:\Program Files\Huawei\DevEco Studio\`) |
| SDK (API 23) | `C:\Program Files\Huawei\DevEco Studio\sdk\` |
| Node.js | 24.x (DevEco 内置) |
| hvigor | 6.0.0 (`tools\hvigor\bin\hvigorw.js`) |
| CMake | DevEco SDK 内置 |
| Rust (OHOS) | aarch64-unknown-linux-ohos / x86_64-unknown-linux-ohos |
| OpenSSL | 3.4.1 静态链接 (libs/openssl/) |
| libssh2 | 静态链接 (libs/libssh2/) |
| FreeRDP | 3.26.1-dev0 (git submodule, 默认 OFF) |

## 构建产物

- `entry/build/default/outputs/default/entry-default-signed.hap` — 签名 HAP (~15MB)
- `entry/build/default/outputs/default/entry-default-unsigned.hap` — 未签名 HAP

## 预期构建结果

```
BUILD SUCCESSFUL in <time> ms
```

## 已知 dirty 状态

- `freerdp/` 子模块始终显示 dirty (`-dirty`)，这是子模块内部文件变更导致，**不要重置它**。
- 重置会丢失 FreeRDP 编译产物，需要重新交叉编译 (~数分钟)。

## 构建选项

| 选项 | 默认值 | 说明 |
|------|--------|------|
| `USE_REAL_FREERDP` | OFF | FreeRDP 真实链接 (需要预编译 libfreerdp3.a + libwinpr3.a) |
| `RDP_BUILD_TESTS` | OFF | 原生 C++ 单元测试 |

## 快速验证命令

```powershell
# 仅编译检查 (不打包)
& 'C:\Program Files\Huawei\DevEco Studio\tools\node\node.exe' 'C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.js' --mode module -p module=entry -p product=default assembleHap --analyze=normal --parallel --incremental --daemon
```

## 设备部署

```powershell
# 安装到真机 (arm64)
hdc -t 192.168.31.222:38451 install -r entry/build/default/outputs/default/entry-default-signed.hap

# 安装到 Pad
hdc -t 192.168.31.223:40123 install -r entry/build/default/outputs/default/entry-default-signed.hap
```
