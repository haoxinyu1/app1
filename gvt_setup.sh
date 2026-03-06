#!/bin/bash
# ============================================================
# FNOS GVT-g 智能适配脚本 - 2026 优化版
# ============================================================

# 检查 root 权限
[[ "$EUID" -ne 0 ]] && echo "❌ 错误：请使用 root 权限运行！" && exit 1

echo "------------------------------------------------------------"
echo "        FNOS GVT-g 智能核显虚拟化助手 (智能寻址版)"
echo "------------------------------------------------------------"

# 1. 自动探测硬件支持
MDEV_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"
[[ ! -d "$MDEV_PATH" ]] && echo "❌ 错误：未检测到 GVT-g 环境，请检查 BIOS 设置。" && exit 1

echo "🔍 1. 检测到硬件支持以下规格："
ls $MDEV_PATH | grep i915
echo "------------------------------------------------------------"

# 2. 输出当前虚拟机列表 (新增步骤)
echo "📋 2. 当前系统中的虚拟机列表："
virsh list --all
echo "------------------------------------------------------------"

# 3. 交互参数
read -p "👉 请输入规格名称 (推荐 i915-GVTg_V4_1): " GVT_TYPE
read -p "👉 请输入目标虚拟机名称: " VM_NAME
[[ -z "$GVT_TYPE" || -z "$VM_NAME" ]] && echo "❌ 错误：输入不能为空。" && exit 1

# 4. 彻底清理旧环境
echo "⏳ 3. 正在清理旧配置..."
systemctl stop fn-gvtg-Passthrough 2>/dev/null
virsh nodedev-destroy mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0 2>/dev/null
virsh nodedev-undefine mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0 2>/dev/null
rm /home/gvtg_*.xml /home/igpu*.xml /usr/local/bin/fn-gvtg-Passthrough.sh 2>/dev/null

# 5. 生成底层硬件定义并启动
cat << EOF > /home/gvtg_v4_1.xml
<device>
  <parent>pci_0000_00_02_0</parent>
  <capability type="mdev">
    <type id="$GVT_TYPE"/>
    <uuid>00000000-0000-0000-0000-000000000011</uuid>
  </capability>
</device>
EOF

virsh nodedev-define /home/gvtg_v4_1.xml
virsh nodedev-autostart mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0
virsh nodedev-start mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0

# 6. 生成智能监控脚本
echo "⚙️ 4. 正在生成智能寻址监控脚本..."
cat << 'EOF' > /usr/local/bin/fn-gvtg-Passthrough.sh
#!/bin/bash
# 智能监控挂载核心逻辑

EOF

# 动态注入配置变量
echo "UUID=\"$VM_NAME\"" >> /usr/local/bin/fn-gvtg-Passthrough.sh
echo "RECORD_FILE=\"/home/gpu_last_slot.txt\"" >> /usr/local/bin/fn-gvtg-Passthrough.sh

cat << 'EOF' >> /usr/local/bin/fn-gvtg-Passthrough.sh
TEMP_XML="/home/igpu_dynamic.xml"
PREF_BUS="08"  # 优先使用 Bus 08 (Q35 根端口)
PREF_SLOT="00"

# 查找可用 PCI 插槽函数
find_free_slot() {
    local vm_xml=$(virsh dumpxml "$UUID" 2>/dev/null)
    # 1. 尝试使用上次成功记录
    if [[ -f "$RECORD_FILE" ]]; then
        local last_info=$(cat "$RECORD_FILE")
        local l_bus=$(echo $last_info | cut -d':' -f1)
        local l_slot=$(echo $last_info | cut -d':' -f2)
        if ! echo "$vm_xml" | grep -q "bus='0x$l_bus' slot='0x$l_slot'"; then
            echo "$l_bus:$l_slot" && return
        fi
    fi
    # 2. 尝试首选预设位址
    if ! echo "$vm_xml" | grep -q "bus='0x$PREF_BUS' slot='0x$PREF_SLOT'"; then
        echo "$PREF_BUS:$PREF_SLOT" && return
    fi
    # 3. 自动扫描可用 Bus (01-08)
    for b in {01..08}; do
        local hex_bus=$(printf "%02x" $b)
        if ! echo "$vm_xml" | grep -q "bus='0x$hex_bus' slot='0x00'"; then
            echo "$hex_bus:00" && return
        fi
    done
}

# 挂载函数
attach_gpu() {
    local slot_info=$(find_free_slot)
    local bus=$(echo $slot_info | cut -d':' -f1)
    local slot=$(echo $slot_info | cut -d':' -f2)
    
    echo "[$(date)] 智能选址: Bus $bus, Slot $slot"
    cat << EXF > "$TEMP_XML"
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci' display='off'>
  <source><address uuid='00000000-0000-0000-0000-000000000011'/></source>
  <address type='pci' domain='0x0000' bus='0x$bus' slot='0x$slot' function='0x0'/>
</hostdev>
EXF

    if virsh attach-device "$UUID" "$TEMP_XML"; then
        echo "[$(date)] ✅ 挂载成功！"
        echo "$bus:$slot" > "$RECORD_FILE"
    else
        echo "[$(date)] ❌ 智能挂载失败，尝试无地址挂载..."
        sed -i '/<address type/d' "$TEMP_XML"
        virsh attach-device "$UUID" "$TEMP_XML"
    fi
}

# 初始补挂检查 (解决硬重启)
[[ $(virsh domstate "$UUID" 2>/dev/null) == "running" ]] && echo "初始补挂载中..." && attach_gpu

previous_state="not exist"
while true; do
    current_state=$(virsh domstate "$UUID" 2>/dev/null)
    [[ $? -ne 0 ]] && current_state="not exist"
    
    if [[ "$current_state" == "running" && "$previous_state" != "running" ]]; then
        echo "[$(date)] 检测到 $UUID 启动，缓冲 8 秒..."
        sleep 8
        attach_gpu
    fi
    previous_state="$current_state"
    sleep 2
done
EOF

chmod +x /usr/local/bin/fn-gvtg-Passthrough.sh

# 7. 注册系统守护服务
echo "🔔 5. 正在配置系统守护服务..."
cat << EOF > /etc/systemd/system/fn-gvtg-Passthrough.service
[Unit]
Description=Smart GVT-g Auto-attach Service
After=libvirtd.service

[Service]
Type=simple
ExecStart=/usr/local/bin/fn-gvtg-Passthrough.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fn-gvtg-Passthrough
systemctl restart fn-gvtg-Passthrough

echo "------------------------------------------------------------"
echo "✨ 智能适配部署完成！"
echo "已为您开启极速监控 (2秒/次)，支持 PCI 位址记忆。"
echo "请运行 journalctl -u fn-gvtg-Passthrough -f 查看实时日志。"
echo "------------------------------------------------------------"
