# 01A DNS 引导：CrushCloud 登录/域名解析异常

> 本页是一个**明确允许、受约束、可回退**的 DNS 引导步骤。
> 它不是“随便改 DNS”，也不是用 DNS 去创造 IPv6 地址。

## 1. 为什么需要这一页

在当前校园网络的已验证环境中，可能出现：

~~~text
物理以太网已经获得校园 IPv6
+
IPv6 默认路由也存在
+
但域名解析异常 / CrushCloud 登录页加载不出来
~~~

这种情况下，如果仍然把“CrushCloud 必须先正常登录”作为 Helper 前置条件，就会形成循环：

~~~text
DNS/解析异常
→ CrushCloud 登录页打不开
→ AI 因为 CrushCloud 未登录而 HOLD
→ 又因为仓库禁止“未验证修改 DNS”而不敢处理 DNS
→ 永远无法进入后续验证
~~~

因此本仓库明确加入这一条 DNS 引导流程。

## 2. 一个重要区分

DNS **不能让 Windows 凭空获得 IPv6 地址**。

所以先检查操作系统网络层：

~~~powershell
Get-NetIPAddress -AddressFamily IPv6 | Format-Table InterfaceIndex,InterfaceAlias,IPAddress,PrefixOrigin,SuffixOrigin,AddressState,SkipAsSource
Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" | Format-Table InterfaceIndex,InterfaceAlias,NextHop,RouteMetric
~~~

### 情况 A：没有校园公网 IPv6 / 没有物理 IPv6 默认路由

不要改 DNS 期待它“生成 IPv6”。

此时应该排查校园网认证、有线链路、DHCPv6 / RA、网卡 IPv6 是否被禁用、当前是否连错网络。

### 情况 B：已经有校园公网 IPv6 + 物理 IPv6 默认路由，但解析/登录异常

这才进入本页 DNS 引导。

> DNS 引导解决的是“已经有 IPv6 链路，但域名/登录端点解析或访问异常”，不是 IPv6 地址分配本身。

## 3. 当前已验证 DNS

当前实验使用阿里公共 DNS 的 IPv6 地址：

~~~text
2400:3200::1
2400:3200:baba::1
~~~

官方公开地址：

https://www.alidns.com/

截至 2026-10-02，阿里公共 DNS 官方页面仍列出：

~~~text
IPv4：223.5.5.5
      223.6.6.6

IPv6：2400:3200::1
      2400:3200:baba::1

DoH/DoT：dns.alidns.com
~~~

本项目 Windows 校园 IPv6 引导优先使用上面的两个 IPv6 DNS。

## 4. 什么时候允许执行

以下条件同时满足时，AI **允许**指导修改物理校园网卡 DNS：

1. 当前连接目标校园有线网络；
2. 校园认证已经完成；
3. Windows IPv6 保持启用；
4. 物理接口已经获得符合当前校园范围的公网 IPv6；
5. 物理接口存在 IPv6 默认路由；
6. 出现域名解析失败、IPv6 测试站点域名打不开、CrushCloud 登录/接口加载失败等现象；
7. 修改前先记录当前 DNS 状态。

如果第 4 或第 5 项不成立，停止，不走 DNS 引导。

## 5. 修改前先记录当前 DNS

先找实际物理校园上行，不要写死 ifIndex：

~~~powershell
$physical = @(Get-NetAdapter -Physical | Where-Object {$_.Status -eq "Up"})
$physicalIndexes = @($physical | ForEach-Object {[int]$_.ifIndex})
$route = Get-NetRoute -AddressFamily IPv6 -DestinationPrefix "::/0" -PolicyStore ActiveStore | Where-Object { $physicalIndexes -contains [int]$_.InterfaceIndex -and $_.NextHop -like "fe80:*" } | Sort-Object RouteMetric | Select-Object -First 1
$route | Format-List InterfaceIndex,InterfaceAlias,NextHop,RouteMetric
Get-DnsClientServerAddress -InterfaceIndex $route.InterfaceIndex | Format-Table InterfaceAlias,InterfaceIndex,AddressFamily,ServerAddresses -AutoSize
~~~

让使用者保存或截图这段输出。

如果当前接口本来就有用户自定义 DNS，不要直接覆盖；先说明并让使用者确认。

## 6. 应用 DNS 引导

确认目标接口正确后：

~~~powershell
Set-DnsClientServerAddress -InterfaceIndex $route.InterfaceIndex -ServerAddresses @("2400:3200::1","2400:3200:baba::1")
Clear-DnsClientCache
~~~

这是**会修改系统设置**的步骤。

修改对象只应是当前检测到的物理校园上行接口。

不要修改虚拟 TUN 接口、所有网卡、参考机 ifIndex，也不要顺便修改 MTU、网关、接口跃点或路由。

## 7. 修改后验证

先看 DNS：

~~~powershell
Get-DnsClientServerAddress -InterfaceIndex $route.InterfaceIndex | Format-Table InterfaceAlias,InterfaceIndex,AddressFamily,ServerAddresses -AutoSize
~~~

再做解析测试：

~~~powershell
Resolve-DnsName www.baidu.com -Server 2400:3200::1 -Type A
Resolve-DnsName www.baidu.com -Server 2400:3200::1 -Type AAAA
Resolve-DnsName www.baidu.com
~~~

然后重新尝试原本打不开的域名、CrushCloud 登录页/登录接口和仓库后续要求的客户端检查。

如果登录恢复，继续后续 CrushCloud / 覆写 / Helper 流程。

如果仍失败，停止，不继续叠加 DNS、路由、MTU 等修改，转入故障排查。

## 7A. DNS 已正常，但 CrushCloud 仍“加载失败”

如果出现：

~~~text
系统 DNS 能正常 Resolve-DnsName
+
指定 2400:3200::1 也能正常解析
+
Windows 已有校园公网 IPv6 和物理 IPv6 默认路由
+
CrushCloud 仍提示“无法加载应用配置”
~~~

此时不要继续反复修改 DNS。

这说明至少“域名解析”这一层已经通过，下一步应定位：

- CrushCloud 实际应用配置接口使用的域名；
- 该接口解析到 IPv4 还是 IPv6；
- TCP 443 是否可达；
- TLS/HTTP 是否成功；
- 是否是服务端接口临时异常；
- 是否是客户端自身版本/配置问题。

优先操作：

1. 点击 CrushCloud 的“导出诊断日志”；
2. 保留失败发生时间；
3. 不要在日志中公开账号、Token、订阅或节点 password；
4. 根据日志中的失败域名/IP，再做只读连通性测试。

如果已知某个失败域名，可先使用：

~~~powershell
Resolve-DnsName <域名>
Test-NetConnection <解析出的IP> -Port 443
~~~

如果是网页入口，还可使用：

~~~powershell
curl.exe -4 -I -L --connect-timeout 5 --max-time 15 https://<域名>/
curl.exe -6 -I -L --connect-timeout 5 --max-time 15 https://<域名>/
~~~

注意：

> “电脑有 IPv6”不等于“某个具体应用配置站点一定提供 AAAA/IPv6 服务”。

如果目标域名只有 A 记录，那么该站点仍依赖 IPv4 可达性；这与校园网物理接口已经获得 IPv6 并不矛盾。

## 8. 回退

如果原来就是“自动获取 DNS / DHCP”，需要恢复时：

~~~powershell
Set-DnsClientServerAddress -InterfaceIndex $route.InterfaceIndex -ResetServerAddresses
Clear-DnsClientCache
~~~

如果修改前原本就是手动自定义 DNS：

- 不要使用 Reset 代替原值；
- 按修改前记录恢复原来的服务器地址。

因此本页要求**修改前一定先记录 DNS 状态**。

## 9. AI 规则

AI 不得因为看到“DNS 修改”四个字就直接 HOLD。

正确判断是：

~~~text
任意/猜测/未记录回退的 DNS 修改
→ 禁止

docs/01A 规定的、满足前置条件的 DNS 引导
→ 允许

没有操作系统层 IPv6 地址/默认路由，却希望改 DNS 得到 IPv6
→ 禁止，方向错误
~~~

> CrushCloud 登录页打不开，不应立即判断“CrushCloud 不可用”。如果 Windows 已经有校园 IPv6 链路，应先检查 DNS 是否属于本页描述的引导场景。