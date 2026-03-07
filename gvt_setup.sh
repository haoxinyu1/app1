#!/bin/bash
# ============================================================
# FNOS Intel GVT-g 终极部署工具 - 架构自适应 & 永久注入
# 目标：将显卡作为“原装硬件”焊死在虚拟机，彻底根治代码 43
# ============================================================

set -e

# --- 样式定义 ---
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export RED='\033[0;31m'
export NC='\033[0m'

INFO="[${BLUE} INFO ${NC}]"
CHECK="[${GREEN}  OK  ${NC}]"
WARN="[${YELLOW} WARN ${NC}]"

# --- 核心变量 ---
UUID="00000000-0000-0000-0000-000000000011"
MDEV_NAME="mdev_${UUID//-/_}_0000_00_02_0"
GRUB_FILE="/etc/default/grub"

echo -e "\n${BLUE}============================================================${NC}"
echo -e "${BLUE}          正在配置 GRUB 引导参数 (DEFAULT 模式)             ${NC}"
echo -e "${BLUE}============================================================${NC}"

# 1. 精准处理 GRUB_CMDLINE_LINUX_DEFAULT
params=("intel_iommu=on" "iommu=pt" "i915.enable_gvt=1")
update_needed=false

for p in "${params[@]}"; do
    if ! grep "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE" | grep -q "$p"; then
        echo -e "${WARN} 缺失关键参数: $p"
        update_needed=true
    fi
done

if [ "$update_needed" = true ]; then
    echo -e "${INFO} 正在备份并更新 $GRUB_FILE ..."
    cp "$GRUB_FILE" "${GRUB_FILE}.bak"
    
    # 优雅注入：在第一个引号后插入参数，确保不破坏原有 quiet splash 等设置
    for p in "${params[@]}"; do
        if ! grep "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE" | grep -q "$p"; then
            sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"/\"$p /" "$GRUB_FILE"
        fi
    done
    
    update-grub
    echo -e "${CHECK} GRUB 配置已更新。${RED}请重启宿主机后再次运行脚本以继续后续步骤。${NC}"
    exit 0
else
    echo -e "${CHECK} GRUB_CMDLINE_LINUX_DEFAULT 已包含所有必要参数。"
fi

echo -e "\n${BLUE}============================================================${NC}"
echo -e "${BLUE}          正在执行硬件切片与永久注入                        ${NC}"
echo -e "${BLUE}============================================================${NC}"

# 2. 探测硬件与虚拟机
PCI_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"
[[ ! -d "$PCI_PATH" ]] && echo -e "${RED}错误：未发现 GVT-g 支持。${NC}" && exit 1

types=($(ls $PCI_PATH))
echo -e "${INFO} 请选择切片类型 (i5-5300U 推荐 V4_1):"
select type in "${types[@]}"; do [[ -n "$type" ]] && break; done

vms=($(virsh list --all --name))
echo -e "${INFO} 请选择目标虚拟机:"
select vm_name in "${vms[@]}"; do [[ -n "$vm_name" ]] && break; done

# 3. 激活底层 mdev 设备
echo -e "${INFO} 正在初始化底层设备 $MDEV_NAME ..."
virsh nodedev-destroy "$MDEV_NAME" 2>/dev/null || true
virsh nodedev-undefine "$MDEV_NAME" 2>/dev/null || true

TEMP_DEF="/tmp/gvtg_def.xml"
cat > "$TEMP_DEF" <<EOF
<device>
  <parent>pci_0000_00_02_0</parent>
  <capability type='mdev'>
    <type id='$type'/>
    <uuid>$UUID</uuid>
  </capability>
</device>
EOF

virsh nodedev-define "$TEMP_DEF"
virsh nodedev-start "$MDEV_NAME"
virsh nodedev-autostart "$MDEV_NAME"

# 4. 永久注入 XML 配置
echo -e "${INFO} 正在将设备永久“焊接”至虚拟机 $vm_name ..."
TEMP_INJECT="/tmp/gpu_inject.xml"
# 锁定 Slot 9 位址，解决 5 代核显在 Windows 里的地址漂移问题
cat > "$TEMP_INJECT" <<EOF
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci' display='off'>
  <source>
    <address uuid='$UUID'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x09' function='0x0'/>
</hostdev>
EOF

# 幂等性清理：先尝试移除旧的同 UUID 设备防止重复
virsh detach-device "$vm_name" "$TEMP_INJECT" --config 2>/dev/null || true
# 永久注入
virsh attach-device "$vm_name" "$TEMP_INJECT" --config

echo -e "\n${GREEN}✨ 部署大功告成！${NC}"
echo -e "${INFO} 引导位置：GRUB_CMDLINE_LINUX_DEFAULT"
echo -e "${INFO} 硬件状态：永久注入 (PCI Slot 09)"
echo -e "${INFO} 状态确认：virsh nodedev-info $MDEV_NAME"
echo -e "${YELLOW}提示：现在直接启动虚拟机即可，显卡驱动将自动加载。${NC}"
echo -e "${BLUE}------------------------------------------------------------${NC}"

rm -f "$TEMP_DEF" "$TEMP_INJECT"
