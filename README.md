### 安装指定版本

```
--version
```

### 日常维护

```
查看日志：  journalctl -u relay-node -f
查看状态：  systemctl status relay-node
停止服务：  systemctl stop relay-node
重启服务：  systemctl restart relay-node
升级：      使用相同的 -t/-u 参数重新运行此安装程序
卸载：      systemctl disable --now relay-node; rm -f /etc/systemd/system/relay-node.service; rm -rf /opt/relay-node
```

### 更新
```
curl -L https://gitlab.com/uyo8os/relay-node/main/relay-node-update-v2.sh -o ecs.sh && chmod +x relay-node-update-v2.sh && bash relay-node-update-v2.sh
```
