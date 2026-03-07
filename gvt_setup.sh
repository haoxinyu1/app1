#!/bin/bash
# ============================================================
# FNOS GVT-g 永久化工具 - 内核加固 & 视觉美化版
# ============================================================

set -e

# --- 样式定义 ---
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export NC='\033[0m'

DONE="[${GREEN}  完成  ${NC}]"
INFO="[${BLUE}  信息  ${NC}]"
WAIT="[${YELLOW}  执行  ${NC}]"
ERROR="[${RED}  错误  ${NC}]"

# --- 变量 ---
UUID="00000000-0000-0000-0000-000000000011"
MDEV_NAME="mdev_${UUID//-/_}_0000_00_02_0"
GRUB_FILE="/etc/default/grub"
MODULES_FILE="/etc/modules"

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${ERROR} 请使用 sudo 运行！" && exit 1

echo -e "\n${BLUE}============================================================${NC}"
echo -e "${BLUE}          飞牛OS GVT-g 永久化部署助手 (智能易读版)          ${NC}"
echo -e "${BLUE}============================================================${NC}"

# --- 第 1 步：内核参数与模块持久化 ---
echo -e "\n${INFO} 1.1 正在优化引导参数 (确保 quiet splash 居首)..."
PARAMS=("intel_iommu=on" "iommu=pt" "i915.enable_gvt=1")
REBOOT_NEEDED=false

for p in "${PARAMS[@]}"; do
    if ! grep "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE" | grep -q "$p"; then
        # 精准尾插：在 DEFAULT 行的最后一个引号前插入参数
        sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ $p\"/" "$GRUB_FILE"
        REBOOT_NEEDED=true
    fi
done

echo -e "${INFO} 1.2 正在载入 5 个核心内核模块..."
CORE_MODS=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd" "kvmgt")
for mod in "${CORE_MODS[@]}"; do
    if ! grep -q "^$mod" "$MODULES_FILE"; then
        echo "$mod" >> "$MODULES_FILE"
        REBOOT_NEEDED=true
    fi
done

if [ "$REBOOT_NEEDED" = true ]; then
    echo -e "${WAIT} 正在同步配置并更新内核镜像 (update-initramfs)..."
    update-grub
    update-initramfs -u -k all
    echo -e "${DONE} 配置已完成加固。${RED}系统必须重启以激活底层支持。${NC}"
    echo -e "${YELLOW}请重启宿主机，开机后再次运行此脚本完成最后一步。${NC}"
    exit 0
fi
echo -e "${DONE} 内核引导与驱动模块已就绪。"

# --- 第 2 步：硬件规格选择 (美化显示) ---
echo -e "\n${INFO} 2. 硬件切片规格选择 (大白话版):"
PCI_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"

if [ ! -d "$PCI_PATH" ]; then
    echo -e "${ERROR} 未发现硬件支持。请确认已重启且 BIOS 开启了 VT-d。"
    exit 1
fi

# 格式化显示切片参数 - 转换为易读格式
types=($(ls "$PCI_PATH" | sort))
echo -e "----------------------------------------------------------------------"
printf "%-5s | %-18s | %-8s | %-12s | %-6s\n" "序号" "规格名称" "显存" "最大分辨率" "可用数"
echo -e "----------------------------------------------------------------------"

for i in "${!types[@]}"; do
    t=${types[$i]}
    DESC=$(cat "$PCI_PATH/$t/description")
    
    # 解析复杂的 description 字符串
    VRAM=$(echo "$DESC" | grep -oP "low_gm_size: \K[^, ]+")
    RESO=$(echo "$DESC" | grep -oP "resolution: \K[^, ]+")
    AVAIL=$(cat "$PCI_PATH/$t/available_instances")
    
    printf " [ %d ] | %-18s | %-8s | %-12s | %-6s\n" "$((i+1))" "$t" "$VRAM" "$RESO" "$AVAIL"
done
echo -e "----------------------------------------------------------------------"

echo -ne "\n${YELLOW}请输入序号选择规格 (Broadwell 推荐选显存最大的 V4_1): ${NC}"
read choice
selected_type=${types[$((choice-1))]}

[[ -z "$selected_type" ]] && echo -e "${ERROR} 选择无效，脚本退出。" && exit 1

# --- 第 3 步：定义并永久注入 ---
echo -e "\n${INFO} 3. 正在激活硬件并注入虚拟机..."
virsh nodedev-destroy "$MDEV_NAME" 2>/dev/null || true
virsh nodedev-undefine "$MDEV_NAME" 2>/dev/null || true

XML_PATH="/home/gvtg-v4.xml"
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

# 寻找虚拟机
vms=($(virsh list --all --name))
echo -e "${YELLOW}请选择目标虚拟机:${NC}"
select vm_name in "${vms[@]}"; do [[ -n "$vm_name" ]] && break; done

INJECT_XML="/tmp/gvtg_inject.xml"
# 固定 PCI 槽位 0x09，防止地址漂移导致 Windows 驱动报错
cat > "$INJECT_XML" <<EOF
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci'>
  <source><address uuid='$UUID'/></source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x09' function='0x0'/>
</hostdev>
EOF

virsh detach-device "$vm_name" "$INJECT_XML" --config 2>/dev/null || true
virsh attach-device "$vm_name" "$INJECT_XML" --config
echo -e "${DONE} 显卡配置已永久注入虚拟机 $vm_name。"

# --- 第 4 步：注册自启服务 ---
echo -e "\n${INFO} 4. 正在配置 Systemd 自启动补丁..."
cat > /etc/systemd/system/mdev-gvtg.service <<EOF
[Unit]
Description=Start mdev GVT-g device
After=libvirtd.service
Wants=libvirtd.service

[Service]
Type=oneshot
ExecStart=/usr/bin/virsh nodedev-start $MDEV_NAME
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mdev-gvtg.service
systemctl start mdev-gvtg.service

echo -e "\n${GREEN}✨ 部署全部完成！${NC}"
echo -e "${INFO} 引导位置：GRUB_CMDLINE_LINUX_DEFAULT (保持首位)"
echo -e "${INFO} 显存规格：$selected_type"
echo -e "${BLUE}------------------------------------------------------------${NC}"
echo -e "${YELLOW}现在直接启动虚拟机即可。如有 Code 43，请在 Win 内安装 15.40.5171 驱动。${NC}"

rm -f "$INJECT_XML"
