#!/bin/bash
# ============================================================
# FNOS GVT-g 终极架构自适应脚本 (2026 稳定版)
# ============================================================

[[ "$EUID" -ne 0 ]] && echo "❌ 需 root 权限" && exit 1

echo "------------------------------------------------------------"
echo "        FNOS GVT-g 架构自适应适配器 (驱动稳固版)"
echo "------------------------------------------------------------"

# 1. 硬件规格探测
MDEV_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"
ls $MDEV_PATH | grep i915
echo "------------------------------------------------------------"
virsh list --all
echo "------------------------------------------------------------"
read -p "👉 规格 (i915-GVTg_V4_1): " GVT_TYPE
read -p "👉 虚拟机名: " VM_NAME

# 2. 基础环境构建
cat << EOF > /home/gvtg_v4_1.xml
<device>
  <parent>pci_0000_00_02_0</parent>
  <capability type="mdev">
    <type id="${GVT_TYPE:-i915-GVTg_V4_1}"/>
    <uuid>00000000-0000-0000-0000-000000000011</uuid>
  </capability>
</device>
EOF
virsh nodedev-define /home/gvtg_v4_1.xml
virsh nodedev-start mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0
virsh nodedev-autostart mdev_00000000_0000_0000_0000_000000000011_0000_00_02_0

# 3. 生成自适应监控脚本
cat << 'EOF' > /usr/local/bin/fn-gvtg-Passthrough.sh
#!/bin/bash
EOF

echo "UUID=\"$VM_NAME\"" >> /usr/local/bin/fn-gvtg-Passthrough.sh

cat << 'EOF' >> /usr/local/bin/fn-gvtg-Passthrough.sh
XML_PATH="/home/igpu_fixed.xml"
RECORD="/home/gpu_last_slot.txt"

# 核心函数：架构感应寻址
find_best_slot() {
    local vm_xml=$(virsh dumpxml "$UUID" 2>/dev/null)
    # 检测是否为 Q35
    if echo "$vm_xml" | grep -q "machine='pc-q35-"; then
        # Q35 架构优先用 Bus 08 或 01
        for b in 08 01 02 03; do
            if ! echo "$vm_xml" | grep -q "bus='0x$b' slot='0x00'"; then
                echo "$b:00" && return
            fi
        done
    else
        # i440FX 架构只能用 Bus 00，避开 00-08 位址
        for s in {09..25}; do
            local hex_s=$(printf "%02x" $s)
            if ! echo "$vm_xml" | grep -q "bus='0x00' slot='0x$hex_s'"; then
                echo "00:$hex_s" && return
            fi
        done
    fi
}

attach_logic() {
    local slot_info=$(find_best_slot)
    local b=$(echo $slot_info | cut -d':' -f1)
    local s=$(echo $slot_info | cut -d':' -f2)
    
    cat << EXF > "$XML_PATH"
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci' display='off'>
  <source><address uuid='00000000-0000-0000-0000-000000000011'/></source>
  <address type='pci' domain='0x0000' bus='0x$b' slot='0x$s' function='0x0'/>
</hostdev>
EXF
    echo "[$(date)] 架构匹配成功，目标位址: Bus $b, Slot $s"
    if virsh attach-device "$UUID" "$XML_PATH"; then
        echo "[$(date)] ✅ 自动挂载成功！"
    else
        echo "[$(date)] ⚠️ 固定挂载受限，执行动态保底挂载..."
        sed -i '/<address type/d' "$XML_PATH"
        virsh attach-device "$UUID" "$XML_PATH"
    fi
}

# 初始检查
[[ $(virsh domstate "$UUID" 2>/dev/null) == "running" ]] && attach_logic

prev="not exist"
while true; do
    curr=$(virsh domstate "$UUID" 2>/dev/null)
    [[ $? -ne 0 ]] && curr="not exist"
    if [[ "$curr" == "running" && "$prev" != "running" ]]; then
        sleep 8
        attach_logic
    fi
    prev="$curr"
    sleep 2
done
EOF

chmod +x /usr/local/bin/fn-gvtg-Passthrough.sh

# 4. 服务注册
cat << EOF > /etc/systemd/system/fn-gvtg-Passthrough.service
[Unit]
Description=Ultimate GVT-g Auto-attach Service
After=libvirtd.service
[Service]
ExecStart=/usr/local/bin/fn-gvtg-Passthrough.sh
Restart=always
[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable fn-gvtg-Passthrough
systemctl restart fn-gvtg-Passthrough
echo "✨ 部署成功！架构已自适应处理。"
