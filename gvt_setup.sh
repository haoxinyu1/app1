#!/bin/bash
# ============================================================
# 飞牛OS Intel GVT-g 永久部署工具 (Broadwell 专用)
# 逻辑：内核参数注入 -> 镜像同步 -> 硬件永久挂载 -> 自启服务
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

# 检查 root 权限
[[ $EUID -ne 0 ]] && echo -e "${ERROR} 请使用 sudo 运行此脚本！" && exit 1

echo -e "${BLUE}============================================================${NC}"
echo -e "${BLUE}          飞牛OS GVT-g 永久化部署助手 (智能自适应)          ${NC}"
echo -e "${BLUE}============================================================${NC}"

# --- 第 1 步：内核参数与引导镜像处理 ---
echo -e "\n${INFO} 1. 正在检查 GRUB 引导参数..."
PARAMS=("intel_iommu=on" "iommu=pt" "i915.enable_gvt=1")
NEED_UPDATE=false

for p in "${PARAMS[@]}"; do
    if ! grep "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE" | grep -q "$p"; then
        echo -e "${YELLOW}[!] 缺失参数: $p${NC}"
        NEED_UPDATE=true
    fi
done

if [ "$NEED_UPDATE" = true ]; then
    echo -e "${WAIT} 正在备份并更新 $GRUB_FILE (注入至 DEFAULT 变量)..."
    cp "$GRUB_FILE" "${GRUB_FILE}.bak"
    
    # 精准注入到 GRUB_CMDLINE_LINUX_DEFAULT 的双引号起始位置
    for p in "${PARAMS[@]}"; do
        if ! grep "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE" | grep -q "$p"; then
            sed -i "/GRUB_CMDLINE_LINUX_DEFAULT=/s/\"/\"$p /" "$GRUB_FILE"
        fi
    done

    echo -e "${WAIT} 正在更新 GRUB 引导记录..."
    update-grub
    
    echo -e "${WAIT} 正在执行 update-initramfs -u -k all (同步内核镜像)..."
    update-initramfs -u -k all
    
    echo -e "${DONE} 配置已成功写入引导镜像。"
    echo -e "${RED}系统必须重启以激活 GVT-g 内核模式。${NC}"
    echo -e "${YELLOW}请重启宿主机，开机后再次运行脚本完成剩余配置。${NC}"
    exit 0
fi
echo -e "${DONE} 内核引导环境已就绪。"

# --- 第 2 步：硬件类型探测与清理 ---
echo -e "\n${INFO} 2. 正在探测硬件支持..."
PCI_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"
if [ ! -d "$PCI_PATH" ]; then
    echo -e "${ERROR} 未发现 GVT-g 硬件支持目录，请确认重启已完成且 BIOS 开启了 VT-d。"
    exit 1
fi

echo -e "${WAIT} 正在清理可能存在的旧设备定义..."
virsh nodedev-destroy "$MDEV_NAME" 2>/dev/null || true
virsh nodedev-undefine "$MDEV_NAME" 2>/dev/null || true

# --- 第 3 步：定义并启动 mdev ---
echo -e "\n${INFO} 3. 正在配置底层虚拟硬件..."
types=($(ls $PCI_PATH))
echo -e "${YELLOW}请选择显存规格 (Broadwell 推荐 V4_8):${NC}"
select type in "${types[@]}"; do
    [[ -n "$type" ]] && break || echo "选择无效"
done

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
echo -e "${DONE} 虚拟显卡设备已在宿主机激活。"

# --- 第 4 步：永久注入虚拟机 ---
echo -e "\n${INFO} 4. 正在确认虚拟机配置..."
vms=($(virsh list --all --name))
if [ ${#vms[@]} -eq 0 ]; then
    echo -e "${ERROR} 未发现任何虚拟机。"
    exit 1
fi

echo -e "${YELLOW}请选择要挂载显卡的虚拟机:${NC}"
select vm_name in "${vms[@]}"; do
    [[ -n "$vm_name" ]] && break || echo "选择无效"
done

INJECT_XML="/tmp/gvtg_inject.xml"
cat > "$INJECT_XML" <<EOF
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci'>
  <source>
    <address uuid='$UUID'/>
  </source>
</hostdev>
EOF

# 使用 --config 进行永久异步注入（等同于手动 virsh edit）
virsh detach-device "$vm_name" "$INJECT_XML" --config 2>/dev/null || true
if virsh attach-device "$vm_name" "$INJECT_XML" --config; then
    echo -e "${DONE} 显卡配置已永久注入虚拟机 $vm_name 的 XML 文件。"
else
    echo -e "${ERROR} 注入失败，请检查虚拟机 XML 格式。"
    exit 1
fi

# --- 第 5 步：开机自启服务 ---
echo -e "\n${INFO} 5. 正在设置开机自动激活服务..."
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
echo -e "${DONE} Systemd 自启服务配置完成。"

# --- 总结 ---
echo -e "\n${GREEN}✨ 全部操作已优雅完成！${NC}"
echo -e "${BLUE}------------------------------------------------------------${NC}"
echo -e "虚拟机名称: ${GREEN}$vm_name${NC}"
echo -e "UUID标识:   ${GREEN}$UUID${NC}"
echo -e "引导镜像:   ${GREEN}已通过 update-initramfs 同步${NC}"
echo -e "参数位置:   ${GREEN}GRUB_CMDLINE_LINUX_DEFAULT${NC}"
echo -e "${BLUE}------------------------------------------------------------${NC}"
echo -e "${YELLOW}现在您可以直接启动虚拟机，显卡驱动将稳定加载。${NC}"

rm -f "$INJECT_XML"
