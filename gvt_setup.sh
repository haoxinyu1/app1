#!/bin/bash
# ============================================================
# 飞牛 OS (FNOS) 核显虚拟化一键配置脚本 (增强版)
# 支持硬件：Intel 5代 - 10代核显 (GVT-g)
# ============================================================

# 检查权限
if [ "$EUID" -ne 0 ]; then 
  echo "错误：请使用 root 权限运行！提示：sudo bash"
  exit 1
fi

clear
echo "------------------------------------------------------------"
echo "        FNOS GVT-g 核显虚拟化一键助手 (云端运行版) "
echo "------------------------------------------------------------"

# 1. 自动探测硬件环境
MDEV_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"
if [ ! -d "$MDEV_PATH" ]; then
    echo "❌ 错误：未检测到 GVT-g 硬件环境。"
    echo "请检查：1. BIOS 是否开启 VT-d 2. 物理机是否开启 iOMMU 和 GVT 支持。"
    exit 1
fi

echo "🔍 检测到你的硬件支持以下切分规格："
ls $MDEV_PATH | grep i915
echo "------------------------------------------------------------"

# 2. 交互获取参数
read -p "👉 请输入规格名称 (例如 i915-GVTg_V4_1): " GVT_TYPE
read -p "👉 请输入虚拟机名称 (例如 xa5ln6tf): " VM_NAME

# 校验输入
if [ -z "$GVT_TYPE" ] || [ -z "$VM_NAME" ]; then
    echo "❌ 错误：输入不能为空。"
    exit 1
fi

# 3. 环境清理
echo "⏳ 正在清理可能存在的冲突配置..."
systemctl stop fn-gvtg-Passthrough 2>/dev/null
virsh nodedev-destroy mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0 2>/dev/null
virsh nodedev-undefine mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0 2>/dev/null
virsh detach-device "$VM_NAME" /home/igpu.xml --config 2>/dev/null

# 4. 写入 XML 配置文件
echo "📝 正在生成硬件定义文件..."
cat << EOF > /home/gvtg_my.xml
<device>
  <name>mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0</name>
  <parent>pci_0000_00_02_0</parent>
  <capability type='mdev'>
    <type id='$GVT_TYPE'/>
    <uuid>00000000-0000-0000-0000-000000000011</uuid>
  </capability>
</device>
EOF

cat << EOF > /home/igpu.xml
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci' display='on'>
  <source>
    <address uuid='00000000-0000-0000-0000-000000000011'/>
  </source>
</hostdev>
EOF

# 5. 激活底层设备
echo "🚀 正在激活虚拟核显设备..."
virsh nodedev-define /home/gvtg_my.xml
virsh nodedev-start mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0
virsh nodedev-autostart mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0

# 6. 创建后台监控脚本 (注意转义 $)
echo "⚙️ 正在配置全自动挂载服务..."
cat << 'EOF' > /usr/local/bin/fn-gvtg-Passthrough.sh
#!/bin/bash
# 参数由生成脚本时注入
EOF

# 动态注入变量到生成的脚本中
echo "UUID=\"$VM_NAME\"" >> /usr/local/bin/fn-gvtg-Passthrough.sh
echo "XML_FILE=\"/home/igpu.xml\"" >> /usr/local/bin/fn-gvtg-Passthrough.sh

cat << 'EOF' >> /usr/local/bin/fn-gvtg-Passthrough.sh
CHECK_INTERVAL=5
previous_state="not exist"

while true; do
    current_state=$(virsh domstate "$UUID" 2>/dev/null)
    if [[ "$current_state" == "running" && "$previous_state" != "running" ]]; then
        echo "[$(date)] 检测到虚拟机开启，执行热插拔挂载..."
        sleep 3
        virsh attach-device "$UUID" "$XML_FILE"
    fi
    previous_state="$current_state"
    sleep $CHECK_INTERVAL
done
EOF

chmod +x /usr/local/bin/fn-gvtg-Passthrough.sh

# 7. 注册 Systemd 服务
cat << EOF > /etc/systemd/system/fn-gvtg-Passthrough.service
[Unit]
Description=FNOS GVT-g Auto Mount Service
After=libvirtd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/fn-gvtg-Passthrough.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fn-gvtg-Passthrough
systemctl start fn-gvtg-Passthrough

echo "------------------------------------------------------------"
echo "✨ 配置完成！"
echo "虚拟机 [$VM_NAME] 已与规格 [$GVT_TYPE] 绑定。"
echo "现在你可以去飞牛网页端启动虚拟机了，显卡会自动注入。"
echo "查看实时日志请用: journalctl -u fn-gvtg-Passthrough -f"
echo "------------------------------------------------------------"
