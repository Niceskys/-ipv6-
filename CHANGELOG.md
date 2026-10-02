# Changelog

## 0.2.4 - 2026-10-02

- 修正首次搭建流程中的 DNS 死锁：不再要求 CrushCloud 必须先成功登录才能处理已知 DNS 引导场景。
- 新增 `docs/01A-DNS引导.md`，明确区分“操作系统没有 IPv6”与“已有 IPv6 但域名/登录异常”。
- 记录当前已验证的阿里公共 IPv6 DNS：`2400:3200::1`、`2400:3200:baba::1`。
- AI 总控/禁止事项/故障排查规则增加受控 DNS 引导例外。
- 从零搭建顺序改为：校园认证 → OS IPv6 检查 → 必要时 DNS 引导 → CrushCloud 登录/覆写 → Helper。
- DNS 引导要求修改前记录原 DNS、只改物理校园上行，并提供回退方法。

## 0.2.3 - 2026-10-02

- 完成一次“干净 Windows + Android”从零流程缺口审计。
- 增加软件下载前的来源/平台/版本/digest 核验门。
- 增加 Windows 11 移动热点从零开启步骤。
- 增加 mixed-port 7890 与 allow-lan 的手机链路前置检查。
- 增加 NekoBox 手动 SOCKS5 配置和推荐启动顺序。
- AI 总控提示词要求实际下载版本偏离基线时先 HOLD，而不是自动追最新版。

## 0.2.2 - 2026-10-02

- 新增 Windows + Android 从零搭建入口。
- 明确电脑端使用 CrushCloud Windows，手机端使用 NekoBox for Android。
- 记录已验证 CrushCloud Windows v2.4.2 基线。
- 固定 NekoBox for Android 1.4.2 参考版本、ARM64 APK 下载地址和 SHA-256。
- README 和 AI 总控提示词支持从完全未安装客户端的环境开始。
- 客户端与手机文档统一引用从零搭建页面，避免下载信息分散。

## 0.2.1 - 2026-10-01

- 完成第一轮通用脚本安全审计。
- 运行时安全门改为安装时记录的精确校园 /64。
- 节点范围使用 CIDR 匹配，默认 `2406:da18::/32`。
- 修复 Windows PowerShell 5.1 下 IPv6 /64 派生的字节移位问题。
- PowerShell 文件加入兼容 Windows PowerShell 5.1 的 UTF-8 BOM。
- 状态文件损坏时改为 Fail-Closed。
- 路由所有权改为修改前记录，恢复失败时保留状态。
- 热点接口变化时增加旧状态恢复保护。
- 降低后台状态文件写入频率。
- ProgramData 工作目录增加 ACL 限制。
- 诊断报告减少非必要本机标识信息。
- CI 增加 PS5/PS7 解析、CIDR 行为测试、覆写脚本功能测试和危险操作静态检查。
- 文档统一为中性、实验性表述。

## 0.2.0 - 2026-10-01

- 加入通用化 `CampusNetworkHelper.ps1`。
- 加入带校园强特征检查的 `Install.ps1`。
- 加入只读 `Check.ps1`。
- 加入所有权感知的 `Uninstall.ps1`。
- 加入 `Collect-Diagnostics.ps1`。
- 加入 Run-Install / Check / Uninstall / Diagnostics CMD 入口。
- 安装器拒绝与旧 `CampusIPv6AutoFix` 同时运行。
- 去除个人 ifIndex、DHCPv6 地址等硬编码。
- 通用版暂标记为测试版，等待第二台独立电脑验证。

## 0.1.0 - 2026-10-01

- 初始化仓库。
- 建立普通用户文档结构。
- 建立 AI 辅助安装与排障规范。
- 加入“纯香港 IPv6”客户端覆写。
- 冻结当前已验证的手机端实验基线。
