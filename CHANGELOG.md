# Changelog

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
