#!/bin/bash
# ============================================================
# FNOS GVT-g 核显虚拟化终极适配脚本 (针对 5 代及以上核显优化)
# 功能：自动切分核显、固定 PCI 位址、严谨监控挂载
# ============================================================

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then 
  echo "错误：请使用 root 权限运行！"
  exit 1
fi

echo "------------------------------------------------------------"
echo "        FNOS GVT-g 核显虚拟化终极一键助手"
echo "------------------------------------------------------------"

# 1. 自动探测硬件支持
MDEV_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"
if [ ! -d "$MDEV_PATH" ]; then
    echo "❌ 错误：未检测到 GVT-g 环境，请确认已开启 BIOS 中的 VT-d 和 iOMMU。"
    exit 1
fi

echo "🔍 检测到你的硬件支持以下规格："
ls $MDEV_PATH | grep i915
echo "------------------------------------------------------------"

# 2. 交互参数
read -p "👉 请输入规格名称 (推荐 i915-GVTg_V4_1): " GVT_TYPE
read -p "👉 请输入虚拟机名称 (当前为 xa5ln6tf): " VM_NAME

if [ -z "$GVT_TYPE" ] || [ -z "$VM_NAME" ]; then
    echo "❌ 错误：输入不能为空。"
    exit 1
fi

# 3. 彻底清理旧环境
echo "⏳ 正在清理旧配置..."
systemctl stop fn-gvtg-Passthrough 2>/dev/null
virsh nodedev-destroy mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0 2>/dev/null
virsh nodedev-undefine mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0 2>/dev/null
virsh detach-device "$VM_NAME" /home/igpu.xml --config 2>/dev/null

# 4. 生成 XML 配置文件 (含固定 PCI 插槽逻辑)
echo "📝 正在生成固定位址的硬件定义..."
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
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci' display='off'>
  <source>
    <address uuid='00000000-0000-0000-0000-000000000011'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x09' function='0x0'/>
</hostdev>
EOF

# 5. 激活底层显卡
echo "🚀 正在启动虚拟核显设备..."
virsh nodedev-define /home/gvtg_my.xml
virsh nodedev-start mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0
virsh nodedev-autostart mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0

# 6. 生成严谨版后台挂载脚本
echo "⚙️ 正在生成严谨版监控脚本..."
cat << 'EOF' > /usr/local/bin/fn-gvtg-Passthrough.sh
#!/bin/bash
# 融合原版逻辑的严谨监控脚本

EOF

echo "UUID=\"$VM_NAME\"" >> /usr/local/bin/fn-gvtg-Passthrough.sh
echo "XML_FILE=\"/home/igpu.xml\"" >> /usr/local/bin/fn-gvtg-Passthrough.sh

cat << 'EOF' >> /usr/local/bin/fn-gvtg-Passthrough.sh
CHECK_INTERVAL=5
previous_state="not exist"

while true; do
    # 严谨获取状态
    current_state=$(virsh domstate "$UUID" 2>/dev/null)
    exit_code=$?
    
    # 处理虚拟机不存在情况
    [[ $exit_code -ne 0 ]] && current_state="not exist"
    
    # 状态变化检测
    if [[ "$current_state" == "running" && "$previous_state" != "running" ]]; then
        echo "[$(date)] 检测到 $UUID 开启，准备热插拔挂载..."
        sleep 3
        if virsh attach-device "$UUID" "$XML_FILE"; then
            echo "[$(date)] ✅ 核显挂载成功！"
        else
            echo "[$(date)] ❌ 错误：挂载失败，请检查 PCI 插槽是否冲突。" >&2
        fi
    fi
    previous_state="$current_state"
    sleep $CHECK_INTERVAL
done
EOF

chmod +x /usr/local/bin/fn-gvtg-Passthrough.sh

# 7. 注册系统服务
echo "🔔 正在注册系统守护服务..."
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
echo "✨ 脚本重写完成并已运行！"
echo "配置：$GVT_TYPE -> $VM_NAME (固定插槽 0x09)"
echo "现在启动虚拟机后，请进入 Windows 最后一次手动安装驱动并重启。"
echo "------------------------------------------------------------"
