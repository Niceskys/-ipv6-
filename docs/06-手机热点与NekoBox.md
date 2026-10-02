# 06 手机热点与 NekoBox

本页为可选模块。只需要电脑端时可以跳过。

## 手机端软件与版本

本项目手机端使用 **NekoBox for Android**，不是 NekoBox Windows 版，也不是 CrushCloud Android 版。

当前基线：NekoBox for Android 1.4.2；现代 ARM64 手机使用 arm64-v8a APK。下载链接和 SHA-256 统一维护在 [00-从零搭建](00-从零搭建.md)。

## Windows 热点

推荐：

- 5 GHz
- 电脑热点地址通常为 192.168.137.1，但必须实际检查
- 热点接口 MTU 在当前测试环境中使用 1400

检查：

~~~powershell
Get-NetIPAddress -AddressFamily IPv4 | Where-Object {$_.IPAddress -like "192.168.137.*"}
netsh interface ipv4 show subinterfaces
~~~

## NekoBox 基线

当前实测较稳定的组合：

~~~text
服务器类型：SOCKS5
服务器：电脑热点地址
端口：7890

TUN：gVisor
MTU：9000
FakeDNS：开启
UDP over TCP：关闭

远程 DNS：AliDNS
直连 DNS：AliDNS

获取唤醒锁：开启
设备从睡眠唤醒时重置出站连接：开启
~~~

SOCKS 自定义出站当前实测更稳定：

~~~json
{
  "network": "tcp"
}
~~~

## 已做过的 A/B 结果

在当前测试手机上：

- 获取唤醒锁：明显改善恢复后的首屏卡顿。
- 睡眠唤醒重置连接：明显改善刚打开应用时的空窗。
- FakeDNS 关闭：无法正常刷视频，因此保留开启。
- UDP over TCP 开启：明显变差，因此关闭。
- SOCKS 限制 TCP：持续刷视频稳定性明显提高。
- gVisor 与 system：体感差异不明显，保留 gVisor。
- TUN MTU 9000 综合表现优于强行改成 1400。

这些是实验结论，不保证不同手机完全一致。
