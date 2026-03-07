#!/bin/bash
# ============================================================
# FNOS GVT-g 终极部署脚本 (内核镜像加固 & 参数调优)
# 针对：Intel Broadwell (5代) CPU 深度优化
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

# --- 变量定义 ---
UUID="00000000-0000-0000-0000-000000000011"
MDEV_NAME="mdev_${UUID//-/_}_0000_00_02_0"
GRUB_FILE="/etc/default/grub"
MODULES_FILE="/etc/modules"

echo -e "\n${BLUE}============================================================${NC}"
echo -e "${BLUE}          飞牛OS GVT-g 永久化部署助手 (内核镜像加固)        ${NC}"
echo -e "${BLUE}============================================================${NC}"

# --- 第 1 步：内核参数与模块持久化 ---
echo -e "\n${INFO} 1.1 正在优化 GRUB 引导参数顺序..."
PARAMS=("intel_iommu=on" "iommu=pt" "i915.enable_gvt=1")
NEED_REFRESH=false

# 确保参数在 quiet splash 之后追加，不改变原有首位位置
for p in "${PARAMS[@]}"; do
    if ! grep "GRUB_CMDLINE_LINUX_DEFAULT" "$GRUB_FILE" | grep -q "$p"; then
        echo -e "${WAIT} 追加参数: $p"
        # 精准匹配：在 DEFAULT 行的最后一个引号前插入参数
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
    
    echo -e "${INFO} 正在同步内核镜像 (update-initramfs -u -k all)..."
    # 该步骤确保模块被物理封装进启动镜像，解决开机识别慢的问题
    update-initramfs -u -k all
    
    echo -e "${DONE} 内核环境已固化至引导镜像。"
    echo -e "${RED}必须重启宿主机以激活底层驱动。${NC}"
    echo -e "${YELLOW}重启后再次运行此脚本完成剩余硬件注入步骤。${NC}"
    exit 0
fi
echo -e "${DONE} 内核与模块环境已就绪。"

# --- 第 2 步：硬件切片激活 ---
echo -e "\n${INFO} 2. 正在检查 GVT-g 硬件支持目录..."
PCI_PATH="/sys/devices/pci0000:00/0000:00:02.0/mdev_supported_types"

if [ ! -d "$PCI_PATH" ]; then
    echo -e "${ERROR} 未发现硬件支持目录。请确认：1. 重启已完成 2. BIOS 开启 VT-d。"
    exit 1
fi

echo -e "${WAIT} 正在清理旧定义并初始化..."
virsh nodedev-destroy "$MDEV_NAME" 2>/dev/null || true
virsh nodedev-undefine "$MDEV_NAME" 2>/dev/null || true

# 选择切片类型
types=($(ls $PCI_PATH))
echo -e "${YELLOW}请选择显存规格 (推荐 V4_8):${NC}"
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
echo -e "${DONE} 虚拟显卡底层设备已激活。"

# --- 第 3 步：虚拟机 XML 永久注入 ---
echo -e "\n${INFO} 3. 正在搜索本地虚拟机..."
vms=($(virsh list --all --name))
if [ ${#vms[@]} -eq 0 ]; then
    echo -e "${ERROR} 未发现虚拟机。"
    exit 1
fi

echo -e "${YELLOW}请选择目标虚拟机:${NC}"
select vm_name in "${vms[@]}"; do
    [[ -n "$vm_name" ]] && break || echo "无效选择"
done

INJECT_XML="/tmp/gvtg_inject.xml"
# 为 5 代核显固定 PCI 插槽，提升 Windows 驱动稳定性
cat > "$INJECT_XML" <<EOF
<hostdev mode='subsystem' type='mdev' managed='no' model='vfio-pci'>
  <source>
    <address uuid='$UUID'/>
  </source>
  <address type='pci' domain='0x0000' bus='0x00' slot='0x09' function='0x0'/>
</hostdev>
EOF

# 使用 --config 进行永久异步注入（等同于手动 virsh edit）
virsh detach-device "$vm_name" "$INJECT_XML" --config 2>/dev/null || true
if virsh attach-device "$vm_name" "$INJECT_XML" --config; then
    echo -e "${DONE} 硬件已成功永久注入虚拟机 $vm_name 的配置中。"
else
    echo -e "${ERROR} XML 注入失败。"
    exit 1
fi

# --- 第 4 步：注册自启服务 ---
echo -e "\n${INFO} 4. 正在配置 Systemd 自启动服务补丁..."
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
echo -e "${DONE} 自启服务配置完成。"

echo -e "\n${GREEN}✨ 部署全部完成！${NC}"
echo -e "${INFO} 引导顺序：$(grep "GRUB_CMDLINE_LINUX_DEFAULT" /etc/default/grub)"
echo -e "${INFO} 加载模块：$(cat /etc/modules | grep -E 'kvmgt|vfio')"
echo -e "${BLUE}------------------------------------------------------------${NC}"
echo -e "${YELLOW}提示：现在直接启动虚拟机，Windows 10 驱动将稳定工作。${NC}"

rm -f "$INJECT_XML"
