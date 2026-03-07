#!/bin/bash
# ============================================================
# FNOS Intel GVT-g 永久化部署脚本 (Broadwell 深度优化版)
# 逻辑：参数保序 -> 镜像固化 -> 硬件定义 -> 永久注入
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

# --- 核心变量 ---
UUID="00000000-0000-0000-0000-000000000011"
MDEV_NAME="mdev_${UUID//-/_}_0000_00_02_0"
GRUB_FILE="/etc/default/grub"
MODULES_FILE="/etc/modules"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${ERROR} 请使用 sudo 运行此脚本！" && exit 1

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}          飞牛OS GVT-g 永久化部署助手 (内核镜像加固)        ${NC}"
echo -e "${BLUE}============================================================${NC}"

# --- 第 1 步：内核参数与模块持久化 (GRUB_DEFAULT 模式) ---
echo -e "\n${INFO} 1.1 正在优化 GRUB 引导参数顺序 (保持 quiet splash 居首)..."
PARAMS=("intel_iommu=on" "iommu=pt" "i915.enable_gvt=1")
NEED_REFRESH=false

for p in "${PARAMS[@]}"; do
    if ! grep "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE" | grep -q "$p"; then
        echo -e "${WAIT} 在行尾追加参数: $p"
        # 匹配 GRUB_CMDLINE_LINUX_DEFAULT 行，在末尾引号前插入空格和参数
        sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"$/ $p\"/" "$GRUB_FILE"
        NEED_REFRESH=true
    fi
done

echo -e "\n${INFO} 1.2 正在将 5 个核心模块写入 $MODULES_FILE ..."
CORE_MODS=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd" "kvmgt")
for mod in "${CORE_MODS[@]}"; do
    if ! grep -q "^$mod" "$MODULES_FILE"; then
        echo -e "${WAIT} 写入模块: $mod"
        echo "$mod" >> "$MODULES_FILE"
        NEED_REFRESH=true
    fi
done

if [ "$NEED_REFRESH" = true ]; then
    echo -e "${INFO} 正在重新生成 GRUB 引导配置..."
    update-grub
    
    echo -e "${INFO} 正在执行 update-initramfs -u -k all (同步模块至内核镜像)..."
    update-initramfs -u -k all
    
    echo -e "${DONE} 内核环境已固化。${RED}系统必须重启以激活底层驱动。${NC}"
    echo -e "${YELLOW}重启后再次运行此脚本完成后续硬件注入。${NC}"
    exit 0
fi
echo -e "${DONE} 内核与模块预载环境已就绪。"

# --- 第 2 步：硬件切片激活 ---
log_header() { echo -e "\n${BLUE}--- $1 ---${NC}"; }
log_header "2. 硬件切片规格选择"

PCI_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"
if [ ! -d "$PCI_PATH" ]; then
    echo -e "${ERROR} 未发现硬件支持目录。请确认：1. 重启已完成 2. BIOS 开启 VT-d。"
    exit 1
fi

echo -e "${BLUE}当前 Broadwell 架构可用规格详情：${NC}"
# 自动读取并显示显存容量
for t in $(ls "$PCI_PATH" | grep "V4"); do
    DESC=$(cat "$PCI_PATH/$t/description")
    AVAIL=$(cat "$PCI_PATH/$t/available_instances")
    echo -e " > ${YELLOW}$t${NC}: $DESC (剩余可用实例: $AVAIL)"
done

types=($(ls "$PCI_PATH" | grep "V4"))
echo -ne "\n${YELLOW}请输入序号选择显存规格 (推荐 V4_8 为 1GB 显存): ${NC}"
select type in "${types[@]}"; do
    [[ -n "$type" ]] && break || echo "无效选择"
done

echo -e "${WAIT} 正在清理旧定义并初始化新切片..."
virsh nodedev-destroy "$MDEV_NAME" 2>/dev/null || true
virsh nodedev-undefine "$MDEV_NAME" 2>/dev/null || true

XML_PATH="/home/gvtg-v4.xml"
cat > "$XML_PATH" <<EOF
<device>
    <parent>pci_0000_00_02_0</parent>
    <capability type="mdev">
        <type id="$type"/>
        <uuid>$UUID</uuid>
    </capability>
</device>
EOF

virsh nodedev-define "$XML_PATH"
virsh nodedev-start "$MDEV_NAME"
echo -e "${DONE} 虚拟显卡底层设备已激活。"

# --- 第 3 步：虚拟机 XML 永久注入 ---
log_header "3. 虚拟机永久挂载"
vms=($(virsh list --all --name))
if [ ${#vms[@]} -eq 0 ]; then
    echo -e "${ERROR} 未发现虚拟机，请先创建 Windows 10。"
    exit 1
fi

echo -e "${YELLOW}请选择要注入显卡的虚拟机:${NC}"
select vm_name in "${vms[@]}"; do
    [[ -n "$vm_name" ]] && break || echo "无效选择"
done

INJECT_XML="/tmp/gvtg_inject.xml"
# 锁定 PCI 槽位 0x09，防止 Windows 重启后地址漂移引发代码 43
cat > "$INJECT_XML" <<EOF
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci'>
  <source>
    <address uuid='$UUID'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x09' function='0x0'/>
</hostdev>
EOF

# 幂等性注入逻辑
virsh detach-device "$vm_name" "$INJECT_XML" --config 2>/dev/null || true
if virsh attach-device "$vm_name" "$INJECT_XML" --config; then
    echo -e "${DONE} 硬件已通过 --config 模式永久注入虚拟机 $vm_name。"
else
    echo -e "${ERROR} XML 注入失败，请手动检查虚拟机配置。"
    exit 1
fi

# --- 第 4 步：注册自启服务补丁 ---
log_header "4. 开机自启服务加固"
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
echo -e "${DONE} Systemd 自启补丁已生效。"

echo -e "\n${GREEN}✨ 全部设置已优雅完成！${NC}"
echo -e "${INFO} GRUB 顺序：$(grep "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE")"
echo -e "${INFO} 显存规格：$type"
echo -e "${INFO} 虚拟槽位：PCI Slot 09"
echo -e "${BLUE}------------------------------------------------------------${NC}"
echo -e "${YELLOW}现在您可以直接启动虚拟机。请记得在 Windows 内安装 15.40.5171 驱动。${NC}"

rm -f "$INJECT_XML"
