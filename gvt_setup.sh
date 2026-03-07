#!/bin/bash
# ============================================================
# 飞牛OS Intel GVT-g 永久部署一键脚本 (Broadwell 专用优化版)
# 遵循指南：https://club.fnnas.com/ (永久添加逻辑)
# ============================================================

set -e

# --- 颜色定义 ---
export GREEN='\033[0;32m'
export BLUE='\033[0;34m'
export YELLOW='\033[1;33m'
export RED='\033[0;31m'
export NC='\033[0m'

# --- 状态图标 ---
DONE="[${GREEN}  完成  ${NC}]"
INFO="[${BLUE}  信息  ${NC}]"
WARN="[${YELLOW}  注意  ${NC}]"
ERROR="[${RED}  错误  ${NC}]"

# --- 核心变量 ---
UUID="00000000-0000-0000-0000-000000000011"
MDEV_NAME="mdev_${UUID//-/_}_0000_00_02_0"
PCI_ADDR="pci_0000_00_02_0"

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${ERROR} 请使用 sudo 运行此脚本！" && exit 1

# 打印美化标题
echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}          飞牛OS GVT-g 永久部署自动化工具 (Broadwell)       ${NC}"
echo -e "${BLUE}============================================================${NC}"

# --- 第 1 步：检查宿主机环境 ---
echo -e "\n${INFO} 1.1 正在检查内核启动参数..."
PARAMS=("intel_iommu=on" "iommu=pt" "i915.enable_gvt=1")
NEED_REBOOT=false

for p in "${PARAMS[@]}"; do
    if ! grep -q "$p" /proc/cmdline; then
        echo -e "${WARN} 缺失参数: $p，正在配置 /etc/default/grub..."
        # 备份并修改
        cp /etc/default/grub /etc/default/grub.bak
        sed -i "/GRUB_CMDLINE_LINUX=/s/\"/\"$p /" /etc/default/grub
        NEED_REBOOT=true
    fi
done

if [ "$NEED_REBOOT" = true ]; then
    echo -e "${INFO} 正在更新 GRUB 引导记录..."
    update-grub
    echo -e "${RED}内核参数已更新，系统必须重启后才能继续下一步。${NC}"
    echo -e "${YELLOW}请重启宿主机，开机后再次运行本脚本。${NC}"
    exit 0
fi
echo -e "${DONE} 内核环境检查通过。"

# --- 第 2 步：清理旧定义 ---
echo -e "\n${INFO} 2. 正在清理可能存在的旧设备定义..."
virsh nodedev-destroy "$MDEV_NAME" 2>/dev/null || true
virsh nodedev-undefine "$MDEV_NAME" 2>/dev/null || true
echo -e "${DONE} 清理完成。"

# --- 第 3 步：创建并启动 mdev 设备 ---
echo -e "\n${INFO} 3. 正在探测硬件支持的 mdev 类型..."
PCI_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"
if [ ! -d "$PCI_PATH" ]; then
    echo -e "${ERROR} 未找到 mdev 目录，请检查 BIOS 中是否开启 VT-d。"
    exit 1
fi

types=($(ls $PCI_PATH))
echo -e "${YELLOW}请选择显存规格 (推荐选择最大规格 V4_8):${NC}"
select type in "${types[@]}"; do
    [[ -n "$type" ]] && break || echo "无效选择"
done

echo -e "${INFO} 正在创建设备定义文件 /home/gvtg-v4.xml ..."
cat > /home/gvtg-v4.xml <<EOF
<device>
    <parent>$PCI_ADDR</parent>
    <capability type="mdev">
        <type id="$type"/>
        <uuid>$UUID</uuid>
    </capability>
</device>
EOF

echo -e "${INFO} 正在激活设备 $MDEV_NAME ..."
virsh nodedev-define /home/gvtg-v4.xml
virsh nodedev-start "$MDEV_NAME"
echo -e "${DONE} 底层虚拟设备已就绪。"

# --- 第 4 步：将设备永久添加到虚拟机 ---
echo -e "\n${INFO} 4. 正在获取虚拟机列表..."
vms=($(virsh list --all --name))
if [ ${#vms[@]} -eq 0 ]; then
    echo -e "${ERROR} 未发现任何虚拟机，请先在网页端创建 Windows 10。"
    exit 1
fi

echo -e "${YELLOW}请选择目标虚拟机:${NC}"
select vm_name in "${vms[@]}"; do
    [[ -n "$vm_name" ]] && break || echo "无效选择"
done

echo -e "${INFO} 正在执行永久注入 (注入 $vm_name XML 配置)..."
# 构建临时注入片段
cat > /tmp/gvtg_inject.xml <<EOF
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci'>
  <source>
    <address uuid='$UUID'/>
  </source>
</hostdev>
EOF

# 幂等性处理：如果已存在则先移除再注入，确保唯一
virsh detach-device "$vm_name" /tmp/gvtg_inject.xml --config 2>/dev/null || true
if virsh attach-device "$vm_name" /tmp/gvtg_inject.xml --config; then
    echo -e "${DONE} 硬件配置已永久写入 $vm_name 的核心配置文件。"
else
    echo -e "${ERROR} 注入失败！请检查虚拟机名称是否正确或 XML 权限。"
    exit 1
fi

# --- 第 5 步：确保宿主机重启后自动激活 ---
echo -e "\n${INFO} 5. 正在配置 Systemd 自启动服务..."
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
echo -e "${DONE} 开机自启服务已创建并启用。"

# --- 完成提示 ---
echo -e "\n${GREEN}✨ 全部设置已完成！${NC}"
echo -e "${BLUE}------------------------------------------------------------${NC}"
echo -e "虚拟机名称: ${GREEN}$vm_name${NC}"
echo -e "显卡位址:   ${GREEN}PCI 总线 0, 设备 8 (虚拟槽位)${NC}"
echo -e "UUID:       ${GREEN}$UUID${NC}"
echo -e "${BLUE}------------------------------------------------------------${NC}"
echo -e "${YELLOW}下一步提示：${NC}"
echo "1. 直接在飞牛网页端启动你的虚拟机。"
echo "2. 进入 Windows 10，显卡将直接以“基本适配器”或“HD 5500”现身。"
echo "3. 运行 15.40.5171 驱动程序并关闭 Windows 快速启动。"
echo -e "${BLUE}------------------------------------------------------------${NC}"

# 清理临时文件
rm -f /tmp/gvtg_inject.xml
