#!/bin/bash
# ============================================================
# 飞牛OS Intel GVT-g 永久部署脚本 (遵循原厂指南版)
# 逻辑：引导参数保序 -> 5大模块固化 -> 硬件定义 -> 永久注入
# ============================================================

set -e

# --- 样式与颜色定义 ---
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export NC='\033[0m'

DONE="[${GREEN}  完成  ${NC}]"
INFO="[${BLUE}  信息  ${NC}]"
WAIT="[${YELLOW}  执行  ${NC}]"
ERROR="[${RED}  错误  ${NC}]"

# --- 核心变量 (严格匹配指南) ---
UUID="00000000-0000-0000-0000-000000000011"
MDEV_NAME="mdev_${UUID//-/_}_0000_00_02_0"
GRUB_FILE="/etc/default/grub"
MODULES_FILE="/etc/modules"
XML_PATH="/home/gvtg-v4.xml"

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${ERROR} 请使用 sudo 运行此脚本！" && exit 1

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}          飞牛OS GVT-g 永久化部署助手 (原味指南版)          ${NC}"
echo -e "${BLUE}============================================================${NC}"

# --- 第 1 步：内核参数与模块持久化 (严格保序) ---
echo -e "\n${INFO} 1.1 正在优化引导参数 (保持 quiet splash 居首)..."
PARAMS=("intel_iommu=on" "iommu=pt" "i915.enable_gvt=1")
NEED_REBOOT=false

for p in "${PARAMS[@]}"; do
    if ! grep "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE" | grep -q "$p"; then
        echo -e "${WAIT} 追加内核参数: $p"
        # 精准匹配：在 DEFAULT 行尾引号前插入空格和参数，不改动行首的 quiet splash
        sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ $p\"/" "$GRUB_FILE"
        NEED_REBOOT=true
    fi
done

echo -e "${INFO} 1.2 正在将 5 个核心模块写入 $MODULES_FILE ..."
CORE_MODS=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd" "kvmgt")
for mod in "${CORE_MODS[@]}"; do
    if ! grep -q "^$mod" "$MODULES_FILE"; then
        echo -e "${WAIT} 载入模块: $mod"
        echo "$mod" >> "$MODULES_FILE"
        NEED_REBOOT=true
    fi
done

if [ "$NEED_REBOOT" = true ]; then
    echo -e "${INFO} 正在更新 GRUB 引导记录..."
    update-grub
    echo -e "${INFO} 正在执行 update-initramfs -u -k all (全量同步镜像)..."
    update-initramfs -u -k all
    echo -e "${DONE} 环境固化完成。${RED}系统必须重启以激活底层驱动。${NC}"
    echo -e "${YELLOW}请重启宿主机，开机后再次运行此脚本完成剩余步骤。${NC}"
    exit 0
fi
echo -e "${DONE} 内核引导与模块环境已就绪。"

# --- 第 2 步：硬件规格选择 ---
echo -e "\n${INFO} 2. 硬件切片规格选择 (实时解析):"
PCI_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"

if [ ! -d "$PCI_PATH" ]; then
    echo -e "${ERROR} 未发现 GVT-g 硬件支持目录，请确认 BIOS 开启了 VT-d。"
    exit 1
fi

types=($(ls "$PCI_PATH" | sort))
echo -e "----------------------------------------------------------------------"
printf "%-5s | %-18s | %-8s | %-12s | %-6s\n" "序号" "规格名称" "专用显存" "最大分辨率" "可用数"
echo -e "----------------------------------------------------------------------"

for i in "${!types[@]}"; do
    t=${types[$i]}
    DESC=$(cat "$PCI_PATH/$t/description")
    VRAM=$(echo "$DESC" | grep -oP "low_gm_size: \K[^, ]+")
    RESO=$(echo "$DESC" | grep -oP "resolution: \K[^, ]+")
    AVAIL=$(cat "$PCI_PATH/$t/available_instances")
    printf " [ %d ] | %-18s | %-8s | %-12s | %-6s\n" "$((i+1))" "$t" "$VRAM" "$RESO" "$AVAIL"
done
echo -e "----------------------------------------------------------------------"

echo -ne "\n${YELLOW}请输入序号选择规格 (Broadwell 推荐 V4_1 显存最大): ${NC}"
read choice
selected_type=${types[$((choice-1))]}
[[ -z "$selected_type" ]] && echo -e "${ERROR} 无效选择。" && exit 1

# --- 第 3 步：创建并启动 mdev (严格匹配 XML) ---
echo -e "\n${INFO} 3. 正在激活硬件并定义设备..."
virsh nodedev-destroy "$MDEV_NAME" 2>/dev/null || true
virsh nodedev-undefine "$MDEV_NAME" 2>/dev/null || true

# 严格还原指南 3.1 节 XML 结构
cat > "$XML_PATH" <<EOF
<device>
    <parent>pci_0000_00_02_0</parent>
    <capability type="mdev">
        <type id="$selected_type"/>
        <uuid>$UUID</uuid>
    </capability>
</device>
EOF

virsh nodedev-define "$XML_PATH"
virsh nodedev-start "$MDEV_NAME"

# --- 第 4 步：永久注入虚拟机 (严格匹配 XML) ---
vms=($(virsh list --all --name))
echo -e "\n${INFO} 4. 正在选择目标虚拟机进行永久挂载..."
select vm_name in "${vms[@]}"; do [[ -n "$vm_name" ]] && break; done

INJECT_XML="/tmp/gvtg_inject.xml"
# 严格还原指南 4.2 节 XML 结构 (无 display='off'，无固定位址)
cat > "$INJECT_XML" <<EOF
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci'>
  <source>
    <address uuid='$UUID'/>
  </source>
</hostdev>
EOF

virsh detach-device "$vm_name" "$INJECT_XML" --config 2>/dev/null || true
if virsh attach-device "$vm_name" "$INJECT_XML" --config; then
    echo -e "${DONE} 显卡配置已永久注入虚拟机 $vm_name。"
else
    echo -e "${ERROR} XML 注入失败。"
    exit 1
fi

# --- 第 5 步：注册自启服务 (幂等性修复) ---
echo -e "\n${INFO} 5. 正在配置 Systemd 自启动服务..."
cat > /etc/systemd/system/mdev-gvtg.service <<EOF
[Unit]
Description=Start mdev GVT-g device
After=libvirtd.service
Wants=libvirtd.service

[Service]
Type=oneshot
# 增加逻辑判断：如果设备已启动则忽略，防止 systemd 状态报错
ExecStart=/bin/bash -c 'virsh nodedev-info $MDEV_NAME | grep -q "Active:.*yes" || virsh nodedev-start $MDEV_NAME'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mdev-gvtg.service
systemctl restart mdev-gvtg.service

echo -e "\n${GREEN}✨ 部署全部完成！已严格遵循指南代码。${NC}"
echo -e "${BLUE}------------------------------------------------------------${NC}"
echo -e "虚拟机名称: ${GREEN}$vm_name${NC}"
echo -e "引导顺序:   ${GREEN}quiet splash ... i915.enable_gvt=1${NC}"
echo -e "载入模块:   ${GREEN}vfio vfio_iommu_type1 vfio_pci vfio_virqfd kvmgt${NC}"
echo -e "${BLUE}------------------------------------------------------------${NC}"

rm -f "$INJECT_XML"
