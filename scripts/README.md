# scripts

v0.2.1 提供第一版通用化脚本。

## 普通用户

最简单的方式：

~~~text
Run-Install.cmd
↓
按提示确认校园网络
↓
Run-Check.cmd
~~~

需要诊断：

~~~text
Run-Diagnostics.cmd
~~~

需要完整撤销本项目修改：

~~~text
Run-Uninstall.cmd
~~~

## PowerShell 文件

### Install.ps1

- 必须管理员权限。
- 检测校园 IPv6 强特征。
- 检测到旧版 `CampusIPv6AutoFix` 时拒绝安装。
- 不写死 ifIndex 或 DHCPv6 地址。
- 生成 `C:\ProgramData\CampusIPv6Lab\config.json`。
- 注册 SYSTEM 计划任务 `CampusIPv6LabHelper`。

### CampusNetworkHelper.ps1

长期运行，默认每 5 秒检查一次。

仅在校园强特征成立时：

- 调整已验证的 IPv6 源地址策略；
- 根据 CrushCloud 实际节点连接添加 /128 物理绕行；
- 在热点存在时管理热点 MTU。

离开校园环境后恢复本项目自己做过的修改。

### Check.ps1

只读检查，不应修改网络。

### Collect-Diagnostics.ps1

生成 `diagnostics-时间.txt`。

不会读取：

- 订阅 URL；
- password；
- Token；
- Cookie；
- 浏览器数据。

### Uninstall.ps1

先停止任务，再调用 Helper 的 `RestoreAndExit` 恢复状态文件记录的修改。恢复失败时拒绝删除状态目录，防止丢失回退信息。

## 测试状态

当前仍是测试版。首次在独立环境部署时，务必运行 Check，并保存输出。
