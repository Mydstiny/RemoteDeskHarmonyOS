# 华为账号登录 — AGC 配置指南

## 前置条件

- 华为开发者账号 (已实名认证)
- DevEco Studio 5.0+
- 本项目已能在真机/模拟器上运行

## 步骤 1: 在 AppGallery Connect 创建应用

1. 打开 [AppGallery Connect](https://developer.huawei.com/consumer/cn/service/josp/agc/index.html)
2. 点击 **我的项目** → **新建项目**
3. 项目名称填写 `RemoteDesktop`，点击确定
4. 进入项目 → **添加应用** → 选择 **HarmonyOS**
5. 填写应用包名 (与 `build-profile.json5` 中 `bundleName` 一致)
6. 创建完成

## 步骤 2: 配置签名指纹

1. 在 DevEco Studio 中: **Build → Generate Key and CSR**
   - 生成 `.p12` 密钥库和 `.csr` 证书请求文件
2. 在 AGC **项目设置 → 常规 → 应用** 页面:
   - 上传 `.csr` 文件 → 下载 `.cer` 证书
   - 下载 `.p7b` Profile 文件
3. 在 DevEco Studio: **File → Project Structure → Signing Configs**
   - 配置 `.p12`、`.cer`、`.p7b` 路径

## 步骤 3: 获取 Client ID

1. 在 AGC → **我的项目 → RemoteDesktop → 常规 → 应用**
2. 找到 **OAuth 2.0 客户端 ID** → 复制
3. 替换 `entry/src/main/module.json5` 中的 `YOUR_AGC_CLIENT_ID`:
   ```json5
   {
     "name": "client_id",
     "value": "你的OAuth2.0客户端ID"
   }
   ```

## 步骤 4: 构建与测试

```bash
# 构建
hvigorw assembleHap

# 部署到真机 (必须真机，模拟器不支持 Account Kit)
hdc -t <设备IP> install -r entry/build/default/outputs/default/entry-default-signed.hap
```

## 步骤 5: 验证登录

1. 打开 App → 看到登录页面
2. 点击 **华为账号登录** 按钮
3. 授权后自动跳转到主页
4. 主页设置 → 账号管理 → 应显示华为账号信息

## 常见问题

| 问题 | 原因 | 解决 |
|------|------|------|
| 登录按钮无反应 | client_id 未配置 | 检查 module.json5 中 client_id |
| 1001500001 错误 | 指纹签名不匹配 | 重新上传 CSR 并下载证书 |
| 1001502014 错误 | 需企业开发者 | 个人开发者使用离线模式 |
| 1001502001 错误 | 未登录华为账号 | 在系统设置中登录华为账号 |

## 端侧架构

```
LoginPage.ets (已有)
  └── authentication.HuaweiIDProvider  (华为 Account Kit API)
       ↓ 成功后
  ┌── AuthService.ets (已有) — 内存会话状态
  └── AccountKitService.ets (新增) — Preferences 持久化凭据
       ↓
  CloudSyncService.ets (新增) — 云同步 (待实现)
       ↓
  你的服务端 API
```

## 下一步

1. **获取 AGC client_id** → 替换 → 构建 → 真机测试登录
2. **搭建后端服务**: 接收 Authorization Code → 换取 Access Token → 返回 Session
3. **实现 CloudSyncService**: 用真实 HTTP 请求替换桩代码
4. **(可选) 申请企业开发者**: 解锁一键登录 (获取手机号)
