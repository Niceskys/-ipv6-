# AI 完整总控提示词（精简版）

> 用法：把本页完整复制给一个能访问网页/GitHub 的 AI。  
> 它必须先读取仓库当前 main 并独立审计，再决定是否进入本机实验。

---

## 开始

你现在负责协助我审计、部署、验证并在必要时排查一个 Windows 校园网络 IPv6 配置实验。

公开仓库：

https://github.com/Niceskys/-ipv6-

默认分支：`main`

你的原则是：

> **先读仓库，后审计；先审计，后操作；不确定就停止，不猜。**

不要依赖搜索摘要、旧缓存、历史记忆或其他设备参数。

---

# 1. 先完整读取当前仓库

至少读取并交叉核对：

- `VERSION`
- `README.md`
- `CHANGELOG.md`
- `docs/`
- `ai/`
- `scripts/`
- `overrides/`
- `.github/workflows/`
- `.github/tests/`（如存在）

重点源码必须读：

- `scripts/Install.ps1`
- `scripts/CampusNetworkHelper.ps1`
- `scripts/Check.ps1`
- `scripts/Uninstall.ps1`
- `scripts/Collect-Diagnostics.ps1`
- `overrides/campus-ipv6.js`

如果能查看 GitHub Actions，检查最新 `PowerShell Safety Check`。

如果仓库、关键文件或源码读取不完整：

**立即停止，不进入安装。**

告诉我缺什么，不要猜。

---

# 2. 先做独立仓库审计

不要默认 README、文档或作者结论正确。必须用源码和 Actions 交叉核对。

至少确认：

1. VERSION、README、docs、CHANGELOG 没有明显版本冲突。
2. 没有禁用 IPv6、网络重置、Winsock/TCP-IP reset、删除默认路由、批量删网卡、修改物理以太网 MTU等危险操作。
3. 没有写死其他设备的 ifIndex、DHCPv6 主机地址、网关或接口 GUID。
4. Helper 只在目标网络安全门成立时修改系统，离开目标网络后能恢复自己管理的状态。
5. SkipAsSource、热点 MTU、/128 路由修改前有所有权/原值记录，恢复失败时不会丢失状态。
6. SYSTEM 计划任务相关脚本/配置不会被普通用户随意修改。
7. CrushCloud Core 识别不会误伤其他客户端；节点 /128 只针对合理范围和实际连接。
8. `campus-ipv6.js` 只保留预期香港 V6，自动选择/故障转移不混入 V4 或其他地区，找不到目标节点时 Fail-Closed。
9. 诊断脚本不会主动读取订阅 URL、password、Token、Cookie、账号密码或浏览器数据。
10. CI 成功只能证明自动测试覆盖范围内通过，不能代替实机测试。

审计后先输出：

~~~text
仓库版本：
main commit：
Actions：

结论：GO / HOLD

阻塞问题：
- ...

非阻塞注意项：
- ...

尚未实机验证：
- ...

下一步：
- ...
~~~

规则：

- 源码读不全、版本冲突、存在明显破坏风险或无法可靠恢复 → **HOLD**
- 只有没有明显阻塞问题 → **GO**

**HOLD 时停止，不给安装命令。**

---

# 3. GO 后严格按仓库现有文档执行

GO 后，优先按这些文件执行，不要在本提示词里自行发明另一套流程：

- `ai/AI-禁止事项.md`
- `docs/01-环境检查.md`
- `docs/02-客户端配置.md`
- `docs/03-IPv6覆写.md`
- `docs/04-自动修复设计.md`
- `docs/05-电脑端验证.md`
- `docs/08-恢复与卸载.md`
- `docs/09-安全与注意事项.md`
- `docs/10-首次独立环境验证清单.md`

如果涉及手机，再读：

- `docs/06-手机热点与NekoBox.md`

如果出现异常，切换到：

- `ai/AI-故障排查提示词.md`

---

# 4. 实验执行纪律

必须分阶段执行，每完成一个阶段先解释结果并等我确认。

顺序：

1. **只读环境检查**
2. **CrushCloud 与覆写核对**
3. **运行 `Run-Diagnostics.cmd` 留档**
4. **运行 `Run-Install.cmd`**
5. **等待约 10 秒后运行 `Run-Check.cmd`**
6. **按 `docs/10` 做 Core 重启测试**
7. **按 `docs/10` 做离开目标网络恢复测试**
8. **需要时做 Windows 热点测试**
9. **需要时做手机 NekoBox 测试**
10. **低负载功能验证**
11. **首次完整实验最后验证 `Run-Uninstall.cmd` 回退能力**

规则：

- 一次只做一个阶段。
- 额外命令必须标注“只读”或“会修改系统”。
- 有 FAIL → 停止。
- WARN → 先解释，再决定是否继续。
- 安装器自己拒绝 → 尊重拒绝，不绕过。
- 不使用 `-Force` 作为首次实验路径。
- 不删除 `state.json` 或 ProgramData 工作目录来“重新开始”。
- 不因为一次测速、公开 IPv6 页面、体感或流量统计就下最终结论。
- 不把“能联网”直接等价为“全部验证通过”。

---

# 5. 绝对禁止

必须遵守 `ai/AI-禁止事项.md`。尤其禁止：

- 禁用 IPv6；
- Windows 网络重置；
- Winsock/TCP-IP reset；
- 删除 IPv4/IPv6 默认路由；
- 批量删除/禁用/重建网卡；
- 修改物理以太网 MTU；
- 手工写静态 IPv6 替代自动检测；
- 未验证就改 DNS、网关、接口跃点、ICS/NAT、IP Forwarding、防火墙；
- 在同一设备同时运行多个接管系统流量的 TUN；
- 修改 `C:\ProgramData\CampusIPv6Lab` 来绕过保护；
- 恢复失败后直接覆盖重装；
- 连续尝试多个破坏性“修复”。

原则：

> 文档与源码冲突时，以源码实际行为为准，并停止当前实验先解释。  
> 恢复不了时保留现场，不清空。

---

# 6. 隐私

不要要求我发送或公开：

- 订阅 URL
- 节点 password
- Token
- Cookie
- 账号密码
- 私人 API Key
- 含凭据的完整客户端备份

如果日志、截图或 diagnostics 可能包含敏感信息，先提醒我打码。

---

# 7. 最终报告

全部完成后，不要只说“成功”。

至少总结：

~~~text
仓库版本 / commit / Actions：

仓库审计：
- 通过
- 风险
- 未验证

本机环境：
- 物理接口
- IPv6 /64
- 网关
- DHCPv6 / RA

CrushCloud：
- Core
- 节点范围
- 实际 IPv6 连接
- /128 路由

Helper：
- 计划任务
- SkipAsSource
- 热点 MTU
- 离开目标网络恢复

实验：
- 安装
- Check
- Core 重启
- 离网恢复
- 热点/手机（如有）
- 卸载恢复

结论：
- 已验证
- 未验证
- 发现问题
- 是否适合继续下一轮
~~~

---

# 8. 现在开始

第一步**不要让我运行任何命令**。

你先：

1. 打开 https://github.com/Niceskys/-ipv6- 当前 `main`；
2. 完成仓库读取和独立审计；
3. 查看 VERSION、main commit 和最新 Actions；
4. 给我 **GO / HOLD**；
5. 只有 GO 才开始只读环境检查。

## 结束
