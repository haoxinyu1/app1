#!/bin/bash
# ==================================================
# 飞牛OS Intel GVT-g 自动配置脚本 (适用于 Broadwell CPU)
# 功能：
#   1. 检查必要内核参数和模块
#   2. 列出可用 mdev 类型，用户选择
#   3. 列出所有虚拟机，用户选择目标虚拟机
#   4. 自动清理旧配置、定义并启动 mdev 设备
#   5. 将设备永久添加到虚拟机 XML
#   6. 创建 systemd 服务实现开机自启
#   7. 提示后续步骤
# ==================================================

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}请以 root 身份运行此脚本！${NC}"
   exit 1
fi

# 固定 UUID（可修改，但必须与虚拟机配置一致）
UUID="00000000-0000-0000-0000-000000000011"
MDEV_NAME="mdev_${UUID//-/_}_0000_00_02_0"

# 检查必要的命令
for cmd in virsh systemctl update-grub; do
    if ! command -v $cmd &> /dev/null; then
        echo -e "${RED}命令 $cmd 未找到，请确保已安装相关软件包。${NC}"
        exit 1
    fi
done

echo -e "${GREEN}=== 步骤1: 检查内核参数 ===${NC}"
if ! grep -q "intel_iommu=on" /proc/cmdline || ! grep -q "i915.enable_gvt=1" /proc/cmdline; then
    echo -e "${YELLOW}内核参数缺少必要选项，正在添加...${NC}"
    # 备份 grub 配置
    cp /etc/default/grub /etc/default/grub.bak
    # 在 GRUB_CMDLINE_LINUX 中添加参数
    sed -i 's/^GRUB_CMDLINE_LINUX="\(.*\)"/GRUB_CMDLINE_LINUX="\1 intel_iommu=on iommu=pt i915.enable_gvt=1"/' /etc/default/grub
    update-grub
    echo -e "${GREEN}内核参数已添加，请重启系统后再次运行此脚本。${NC}"
    exit 0
else
    echo -e "${GREEN}内核参数正确。${NC}"
fi

echo -e "${GREEN}=== 步骤2: 检查内核模块 ===${NC}"
REQUIRED_MODULES=("kvmgt" "mdev" "vfio" "vfio_iommu_type1" "vfio_pci")
for mod in "${REQUIRED_MODULES[@]}"; do
    if ! lsmod | grep -q "^$mod"; then
        echo -e "${YELLOW}模块 $mod 未加载，尝试加载...${NC}"
        modprobe $mod || echo -e "${RED}加载 $mod 失败，请检查内核支持。${NC}"
    fi
done

echo -e "${GREEN}=== 步骤3: 选择 mdev 类型 ===${NC}"
PCI_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"
if [ ! -d "$PCI_PATH" ]; then
    echo -e "${RED}未找到 mdev 支持类型目录，请确认 GVT-g 已正确启用。${NC}"
    exit 1
fi

echo "可用 mdev 类型："
types=($(ls $PCI_PATH))
if [ ${#types[@]} -eq 0 ]; then
    echo -e "${RED}没有可用的 mdev 类型，您的硬件可能不支持 GVT-g。${NC}"
    exit 1
fi

select type in "${types[@]}"; do
    if [ -n "$type" ]; then
        echo -e "${GREEN}您选择了: $type${NC}"
        break
    else
        echo -e "${RED}无效选择，请重新输入序号。${NC}"
    fi
done

echo -e "${GREEN}=== 步骤4: 选择目标虚拟机 ===${NC}"
vm_list=$(virsh list --all --name | grep -v '^$')
if [ -z "$vm_list" ]; then
    echo -e "${RED}没有找到任何虚拟机，请先创建虚拟机。${NC}"
    exit 1
fi

echo "可用的虚拟机："
select vm_name in $vm_list; do
    if [ -n "$vm_name" ]; then
        echo -e "${GREEN}您选择了: $vm_name${NC}"
        break
    else
        echo -e "${RED}无效选择，请重新输入序号。${NC}"
    fi
done

echo -e "${GREEN}=== 步骤5: 清理旧配置 ===${NC}"
# 停止并删除同名的 mdev 设备（如果存在）
if virsh nodedev-info "$MDEV_NAME" &>/dev/null; then
    echo "发现已存在的设备 $MDEV_NAME，正在删除..."
    virsh nodedev-destroy "$MDEV_NAME" 2>/dev/null || true
    virsh nodedev-undefine "$MDEV_NAME" 2>/dev/null || true
fi

echo -e "${GREEN}=== 步骤6: 定义并启动新的 mdev 设备 ===${NC}"
XML_FILE="/tmp/gvtg-${type}.xml"
cat > "$XML_FILE" <<EOF
<device>
    <parent>pci_0000_00_02_0</parent>
    <capability type="mdev">
        <type id="$type"/>
        <uuid>$UUID</uuid>
    </capability>
</device>
EOF

virsh nodedev-define "$XML_FILE"
virsh nodedev-start "$MDEV_NAME"
rm -f "$XML_FILE"

echo -e "${GREEN}mdev 设备已启动。${NC}"

echo -e "${GREEN}=== 步骤7: 将设备永久添加到虚拟机 ===${NC}"
# 备份虚拟机配置
BACKUP_FILE="/tmp/${vm_name}.xml.bak"
virsh dumpxml "$vm_name" > "$BACKUP_FILE"
echo "已备份当前配置到 $BACKUP_FILE"

# 构造要添加的 hostdev 片段
HOSTDEV_XML=$(cat <<EOF
  <hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci'>
    <source>
      <address uuid='$UUID'/>
    </source>
  </hostdev>
EOF
)

# 使用 virsh edit 进行编辑（通过临时文件）
TEMP_XML=$(mktemp)
virsh dumpxml "$vm_name" > "$TEMP_XML"

# 在 </devices> 之前插入 hostdev 片段（如果没有则添加）
if grep -q "</devices>" "$TEMP_XML"; then
    sed -i "/<\/devices>/i $HOSTDEV_XML" "$TEMP_XML"
else
    echo -e "${RED}无法在 XML 中找到 </devices> 标签，请手动添加。${NC}"
    exit 1
fi

# 验证并更新
if virsh define "$TEMP_XML"; then
    echo -e "${GREEN}虚拟机配置已更新。${NC}"
else
    echo -e "${RED}更新失败，请检查 XML 语法。恢复备份中...${NC}"
    virsh define "$BACKUP_FILE"
    exit 1
fi
rm -f "$TEMP_XML"

echo -e "${GREEN}=== 步骤8: 创建 systemd 开机自启服务 ===${NC}"
SERVICE_FILE="/etc/systemd/system/mdev-gvtg.service"
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Start mdev GVT-g device
After=libvirtd.service
Wants=libvirtd.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'if ! virsh nodedev-info $MDEV_NAME | grep -q "Active:.*yes"; then virsh nodedev-start $MDEV_NAME; fi'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mdev-gvtg.service
systemctl start mdev-gvtg.service

echo -e "${GREEN}服务已创建并启动。${NC}"

echo -e "${GREEN}=== 配置完成！===${NC}"
echo -e "${YELLOW}请执行以下操作：${NC}"
echo "1. 重启宿主机，验证 mdev 设备自动激活："
echo "   sudo virsh nodedev-info $MDEV_NAME"
echo "2. 启动虚拟机 $vm_name，进入 Windows 检查显卡驱动。"
echo "3. 如需调整显存大小，可重新运行本脚本选择其他 mdev 类型。"
echo -e "${GREEN}脚本执行完毕。${NC}"
