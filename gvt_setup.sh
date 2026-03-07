#!/bin/bash
# ============================================================
# FNOS GVT-g 永久部署脚本 (内核镜像加固 & 参数精准保序版)
# 针对：Intel Broadwell (5代) CPU 深度优化
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

# --- 变量定义 ---
UUID="00000000-0000-0000-0000-000000000011"
MDEV_NAME="mdev_${UUID//-/_}_0000_00_02_0"
GRUB_FILE="/etc/default/grub"
MODULES_FILE="/etc/modules"

# 检查权限
[[ $EUID -ne 0 ]] && echo -e "${ERROR} 请使用 sudo 运行此脚本！" && exit 1

echo -e "\n${BLUE}============================================================${NC}"
echo -e "${BLUE}          飞牛OS GVT-g 永久化部署助手 (智能对齐版)          ${NC}"
echo -e "${BLUE}============================================================${NC}"

# --- 第 1 步：内核参数与模块持久化 ---
echo -e "\n${INFO} 1.1 正在检查引导参数 (确保 quiet splash 居首)..."
PARAMS=("intel_iommu=on" "iommu=pt" "i915.enable_gvt=1")
NEED_REFRESH=false

for p in "${PARAMS[@]}"; do
    if ! grep "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE" | grep -q "$p"; then
        # 在行尾引号前插入参数，保留开头的 quiet splash
        sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ $p\"/" "$GRUB_FILE"
        NEED_REFRESH=true
    fi
done

echo -e "${INFO} 1.2 正在将 5 个核心模块同步至 $MODULES_FILE ..."
CORE_MODS=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd" "kvmgt")
for mod in "${CORE_MODS[@]}"; do
    if ! grep -q "^$mod" "$MODULES_FILE"; then
        echo "$mod" >> "$MODULES_FILE"
        NEED_REFRESH=true
    fi
done

if [ "$NEED_REFRESH" = true ]; then
    echo -e "${WAIT} 正在重新生成引导并同步内核镜像 (initramfs)..."
    update-grub
    update-initramfs -u -k all
    echo -e "${DONE} 环境加固完成。${RED}系统必须重启以激活底层支持。${NC}"
    echo -e "${YELLOW}请重启宿主机，开机后再次运行此脚本完成硬件挂载。${NC}"
    exit 0
fi
echo -e "${DONE} 内核引导环境已就绪。"

# --- 第 2 步：硬件切片规格选择 (精准对齐) ---
echo -e "\n${INFO} 2. 硬件切片规格详情 (已根据您的系统实时解析):"
PCI_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"

if [ ! -d "$PCI_PATH" ]; then
    echo -e "${ERROR} 未发现硬件支持目录。请确认重启已完成且 BIOS 开启了 VT-d。"
    exit 1
fi

# 格式化显示切片参数
types=($(ls "$PCI_PATH" | sort))
for i in "${!types[@]}"; do
    t=${types[$i]}
    DESC=$(cat "$PCI_PATH/$t/description" | tr -d '\n' | sed 's/,/ | /g')
    AVAIL=$(cat "$PCI_PATH/$t/available_instances")
    echo -e "  [ $((i+1)) ] ${YELLOW}$t${NC}: $DESC (剩余: $AVAIL)"
done

echo -ne "\n${YELLOW}请输入序号选择规格: ${NC}"
read choice
selected_type=${types[$((choice-1))]}

if [ -z "$selected_type" ]; then
    echo -e "${ERROR} 无效选择，脚本退出。"
    exit 1
fi

echo -e "\n${WAIT} 正在初始化底层设备 $MDEV_NAME ..."
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
echo -e "${DONE} 虚拟显卡底层设备已激活。"

# --- 第 3 步：虚拟机永久注入 ---
echo -e "\n${INFO} 3. 正在搜索本地虚拟机..."
vms=($(virsh list --all --name))
echo -e "${YELLOW}请选择目标虚拟机:${NC}"
select vm_name in "${vms[@]}"; do
    [[ -n "$vm_name" ]] && break || echo "无效选择"
done

INJECT_XML="/tmp/gvtg_inject.xml"
# 锁定 PCI 槽位 0x09，规避 Broadwell 地址漂移导致的驱动报错
cat > "$INJECT_XML" <<EOF
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci'>
  <source>
    <address uuid='$UUID'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x09' function='0x0'/>
</hostdev>
EOF

virsh detach-device "$vm_name" "$INJECT_XML" --config 2>/dev/null || true
if virsh attach-device "$vm_name" "$INJECT_XML" --config; then
    echo -e "${DONE} 硬件已成功永久注入 $vm_name 的核心配置。"
else
    echo -e "${ERROR} 注入失败。"
    exit 1
fi

# --- 第 4 步：开机自启服务 ---
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
echo -e "${DONE} 自启服务已就绪。"

echo -e "\n${GREEN}✨ 部署全部完成！${NC}"
echo -e "${INFO} 参数顺序：$(grep "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub)"
echo -e "${INFO} 位址锁定：PCI Slot 09"
echo -e "${BLUE}------------------------------------------------------------${NC}"
echo -e "${YELLOW}现在您可以直接从飞牛网页端启动虚拟机了。${NC}"

rm -f "$INJECT_XML"
