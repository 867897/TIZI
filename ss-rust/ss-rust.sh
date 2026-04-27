#!/usr/bin/env bash
set -o pipefail
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin
export PATH

#=================================================
#	System Required: CentOS 7+/Debian 10+/Ubuntu 18.04+
#	Description: Install shadowsocks-rust (AEAD / SS-2022)
#	Version: 1.0.0
#=================================================

sh_ver="1.0.0"

#----- 镜像源（与 ssr.sh 同仓库，独立子目录 ss-rust/）-----
# 仓库结构（你需要先把以下文件放进去）：
#   867897/TIZI (branch: main)
#     └─ ss-rust/
#         ├─ shadowsocks-v1.21.2.x86_64-unknown-linux-gnu.tar.xz   (从 GitHub Releases 下载后原样上传)
#         ├─ shadowsocks-v1.21.2.aarch64-unknown-linux-gnu.tar.xz  (可选, ARM64 服务器)
#         └─ ss-rust.sh                                             (本脚本自身, 自更新用)
MIRROR_OWNER="867897"
MIRROR_REPO="TIZI"
MIRROR_REF="main"
MIRROR_SUBDIR="ss-rust"

# shadowsocks-rust 版本（升级时改这里 + 重新算 SHA-256）
SS_RUST_VER="v1.24.0"

RAW_BASE="https://raw.githubusercontent.com/${MIRROR_OWNER}/${MIRROR_REPO}/${MIRROR_REF}/${MIRROR_SUBDIR}"
SS_X64_TAR="shadowsocks-${SS_RUST_VER}.x86_64-unknown-linux-gnu.tar.xz"
SS_ARM64_TAR="shadowsocks-${SS_RUST_VER}.aarch64-unknown-linux-gnu.tar.xz"
SS_X64_URL="${RAW_BASE}/${SS_X64_TAR}"
SS_ARM64_URL="${RAW_BASE}/${SS_ARM64_TAR}"
SELF_UPDATE_URL="${RAW_BASE}/ss-rust.sh"

# SHA-256 校验。强烈建议把官方 release 里的 .sha256 文件值贴进来。
# 官方:  https://github.com/shadowsocks/shadowsocks-rust/releases
#        每个 .tar.xz 旁边都有 .sha256 文件
SS_X64_SHA256="5f528efb4e51e732352f5c69538dcc76e8cf8f6d1a240dfb5b748a67f0b05f65"
SS_ARM64_SHA256="dc56150cb263e1e150af33cc4c6542035aab3edf602e340842cca4138a4d5c51"
SELF_UPDATE_SHA256=""

#----- 路径/常量 -----
ss_folder="/usr/local/shadowsocks-rust"
ss_bin="${ss_folder}/ssserver"
ss_config_dir="/etc/shadowsocks-rust"
ss_config_file="${ss_config_dir}/config.json"
ss_systemd_unit="/etc/systemd/system/ss-rust.service"
ss_log_file="/var/log/ss-rust.log"

Green_font_prefix="\033[32m"; Red_font_prefix="\033[31m"
Green_bg="\033[42;37m"; Red_bg="\033[41;37m"; Reset="\033[0m"
Info="${Green_font_prefix}[信息]${Reset}"
Error="${Red_font_prefix}[错误]${Reset}"
Tip="${Green_font_prefix}[注意]${Reset}"
SEP="——————————————————————————————"

#----- 通用工具 -----
check_root(){
	[[ $EUID != 0 ]] && echo -e "${Error} 需要 ROOT 权限，请用 sudo su 后重试。" && exit 1
}

check_sys(){
	if [[ -f /etc/redhat-release ]]; then
		release="centos"
	elif grep -qiE "debian" /etc/issue 2>/dev/null || grep -qi "debian" /etc/os-release 2>/dev/null; then
		release="debian"
	elif grep -qiE "ubuntu" /etc/issue 2>/dev/null || grep -qi "ubuntu" /etc/os-release 2>/dev/null; then
		release="debian"
	else
		echo -e "${Error} 不支持的系统，本脚本仅支持 CentOS / Debian / Ubuntu。" && exit 1
	fi
}

detect_arch(){
	local m; m=$(uname -m)
	case "${m}" in
		x86_64|amd64) arch="x86_64"; ss_tar_url="${SS_X64_URL}"; ss_tar_name="${SS_X64_TAR}"; ss_tar_sha="${SS_X64_SHA256}" ;;
		aarch64|arm64) arch="aarch64"; ss_tar_url="${SS_ARM64_URL}"; ss_tar_name="${SS_ARM64_TAR}"; ss_tar_sha="${SS_ARM64_SHA256}" ;;
		*) echo -e "${Error} 不支持的 CPU 架构: ${m}（仅支持 x86_64 / aarch64）" && exit 1 ;;
	esac
}

# 安全下载：强制 TLS、失败重试，可选 SHA-256
safe_download(){
	# usage: safe_download <url> <dest> [sha256]
	local url="$1" dest="$2" sum="$3"
	if command -v curl >/dev/null 2>&1; then
		curl -fSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -o "${dest}" "${url}" || return 1
	else
		wget --https-only --tries=3 --timeout=20 -O "${dest}" "${url}" || return 1
	fi
	if [[ -n "${sum}" ]]; then
		echo "${sum}  ${dest}" | sha256sum -c - >/dev/null 2>&1 || {
			echo -e "${Error} 文件 SHA-256 校验失败: ${dest}" >&2
			rm -f "${dest}"
			return 2
		}
	else
		echo -e "${Tip} 未配置 SHA-256，已跳过校验：${dest}"
	fi
	return 0
}

install_deps(){
	if [[ ${release} == "centos" ]]; then
		yum install -y curl tar xz jq iproute >/dev/null 2>&1 || \
		dnf install -y curl tar xz jq iproute >/dev/null 2>&1
	else
		apt-get update -y >/dev/null 2>&1
		apt-get install -y curl tar xz-utils jq iproute2 >/dev/null 2>&1
	fi
}

random_password(){
	# SS-2022 的 PSK 必须是 base64(随机字节)，长度按算法定：
	#   2022-blake3-aes-128-gcm   -> 16 字节
	#   2022-blake3-aes-256-gcm   -> 32 字节
	#   2022-blake3-chacha20-poly1305 -> 32 字节
	# 经典 AEAD-2017 直接给一段强随机字符串即可
	local n="$1"
	head -c "${n}" /dev/urandom | base64 -w0
}

#----- 配置交互 -----
Set_port(){
	while :; do
		read -e -p "请输入端口 (默认: 35567):" ss_port
		[[ -z "${ss_port}" ]] && ss_port="35567"
		if [[ "${ss_port}" =~ ^[0-9]+$ ]] && (( ss_port>=1 && ss_port<=65535 )); then
			break
		fi
		echo -e "${Error} 请输入 1-65535 之间的端口号。"
	done
}

Set_method(){
	echo -e "请选择加密算法

 ${Green_font_prefix}--- SS-2022 (推荐, 带重放保护) ---${Reset}
 ${Green_font_prefix}1.${Reset} 2022-blake3-aes-256-gcm        ${Tip} 推荐, AES-NI CPU 最快
 ${Green_font_prefix}2.${Reset} 2022-blake3-aes-128-gcm
 ${Green_font_prefix}3.${Reset} 2022-blake3-chacha20-poly1305  ${Tip} 移动端/无 AES-NI 推荐

 ${Green_font_prefix}--- SS-AEAD-2017 (经典, 兼容老客户端) ---${Reset}
 ${Green_font_prefix}4.${Reset} aes-256-gcm
 ${Green_font_prefix}5.${Reset} aes-128-gcm
 ${Green_font_prefix}6.${Reset} chacha20-ietf-poly1305" && echo
	read -e -p "(默认: 1):" m
	[[ -z "${m}" ]] && m="1"
	case "${m}" in
		1) ss_method="2022-blake3-aes-256-gcm";       ss_psk_bytes=32 ;;
		2) ss_method="2022-blake3-aes-128-gcm";       ss_psk_bytes=16 ;;
		3) ss_method="2022-blake3-chacha20-poly1305"; ss_psk_bytes=32 ;;
		4) ss_method="aes-256-gcm";       ss_psk_bytes=0 ;;
		5) ss_method="aes-128-gcm";       ss_psk_bytes=0 ;;
		6) ss_method="chacha20-ietf-poly1305"; ss_psk_bytes=0 ;;
		*) ss_method="2022-blake3-aes-256-gcm";       ss_psk_bytes=32 ;;
	esac
	echo -e "  加密 : ${Green_font_prefix}${ss_method}${Reset}"
}

Set_password(){
	if (( ss_psk_bytes > 0 )); then
		ss_password=$(random_password "${ss_psk_bytes}")
		echo -e "  密码 : ${Green_font_prefix}${ss_password}${Reset}  ${Tip} SS-2022 PSK 必须随机, 已自动生成"
	else
		read -e -p "请输入密码 (留空自动生成 24 字节随机):" ss_password
		[[ -z "${ss_password}" ]] && ss_password=$(random_password 24)
		echo -e "  密码 : ${Green_font_prefix}${ss_password}${Reset}"
	fi
}

write_config(){
	mkdir -p "${ss_config_dir}"
	chmod 700 "${ss_config_dir}"
	cat > "${ss_config_file}" <<EOF
{
    "server": "::",
    "server_port": ${ss_port},
    "password": "${ss_password}",
    "method": "${ss_method}",
    "mode": "tcp_and_udp",
    "fast_open": false,
    "no_delay": true,
    "timeout": 300
}
EOF
	chmod 600 "${ss_config_file}"
}

write_systemd(){
	cat > "${ss_systemd_unit}" <<EOF
[Unit]
Description=Shadowsocks-rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ss_bin} -c ${ss_config_file}
Restart=on-failure
RestartSec=3s
LimitNOFILE=65535
# 安全加固
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ReadWritePaths=/var/log
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable ss-rust >/dev/null 2>&1
}

open_firewall(){
	if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
		firewall-cmd --permanent --add-port=${ss_port}/tcp >/dev/null 2>&1
		firewall-cmd --permanent --add-port=${ss_port}/udp >/dev/null 2>&1
		firewall-cmd --reload >/dev/null 2>&1
	elif command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
		ufw allow ${ss_port}/tcp >/dev/null 2>&1
		ufw allow ${ss_port}/udp >/dev/null 2>&1
	fi
}

#----- 安装 / 卸载 / 控制 -----
Install_ss_rust(){
	check_root; check_sys; detect_arch
	if [[ -x "${ss_bin}" ]]; then
		echo -e "${Tip} 已安装。如需重装请先执行: bash $0 uninstall"
		exit 0
	fi
	install_deps

	echo -e "${Info} 下载 shadowsocks-rust ${SS_RUST_VER} (${arch}) ..."
	local tmpdir; tmpdir=$(mktemp -d)
	safe_download "${ss_tar_url}" "${tmpdir}/${ss_tar_name}" "${ss_tar_sha}" || {
		echo -e "${Error} 下载失败，请检查仓库内是否已上传 ${ss_tar_name}"
		rm -rf "${tmpdir}"; exit 1
	}

	mkdir -p "${ss_folder}"
	tar -xJf "${tmpdir}/${ss_tar_name}" -C "${tmpdir}" || {
		echo -e "${Error} 解压失败"; rm -rf "${tmpdir}"; exit 1
	}
	# 官方 release tar 内是扁平结构: ssserver / sslocal / ssmanager / ssservice / ssurl
	install -m 0755 "${tmpdir}/ssserver" "${ss_bin}" 2>/dev/null || \
	install -m 0755 "$(find "${tmpdir}" -name ssserver -type f | head -1)" "${ss_bin}"
	[[ ! -x "${ss_bin}" ]] && { echo -e "${Error} 未找到 ssserver 可执行文件"; rm -rf "${tmpdir}"; exit 1; }
	rm -rf "${tmpdir}"

	echo && echo "${SEP}"
	Set_port
	Set_method
	Set_password
	echo "${SEP}" && echo

	write_config
	write_systemd
	open_firewall

	systemctl restart ss-rust
	sleep 1
	if systemctl is-active ss-rust >/dev/null 2>&1; then
		echo -e "${Info} 安装并启动成功。"
		View_info
	else
		echo -e "${Error} 启动失败，最近日志："
		journalctl -u ss-rust -n 30 --no-pager
		exit 1
	fi
}

Uninstall_ss_rust(){
	check_root
	read -e -p "确认卸载 shadowsocks-rust？[y/N]:" yn
	[[ "${yn,,}" != "y" ]] && exit 0
	systemctl stop ss-rust 2>/dev/null
	systemctl disable ss-rust 2>/dev/null
	rm -f "${ss_systemd_unit}"
	systemctl daemon-reload
	rm -rf "${ss_folder}" "${ss_config_dir}"
	echo -e "${Info} 已卸载。日志文件 ${ss_log_file}（如有）保留，请自行删除。"
}

Start_ss_rust(){ check_root; systemctl start ss-rust && echo -e "${Info} 已启动" || echo -e "${Error} 启动失败"; }
Stop_ss_rust(){ check_root; systemctl stop ss-rust && echo -e "${Info} 已停止"; }
Restart_ss_rust(){ check_root; systemctl restart ss-rust && echo -e "${Info} 已重启" && View_info; }

Status_ss_rust(){
	systemctl status ss-rust --no-pager
}

Modify_config(){
	check_root
	[[ ! -f "${ss_config_file}" ]] && { echo -e "${Error} 未安装"; exit 1; }
	echo "${SEP}"
	Set_port
	Set_method
	Set_password
	echo "${SEP}"
	# 旧端口防火墙规则不主动清理（用户可能有其它服务）
	write_config
	open_firewall
	systemctl restart ss-rust
	sleep 1
	systemctl is-active ss-rust >/dev/null 2>&1 && View_info || journalctl -u ss-rust -n 30 --no-pager
}

# 生成 ss:// 链接（标准 SIP002，单密码）
gen_ss_link(){
	local ip="$1" port="$2" method="$3" pwd="$4"
	# userinfo = base64url( method:password )，无填充
	local userinfo
	userinfo=$(printf '%s:%s' "${method}" "${pwd}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
	# IPv6 加方括号
	if [[ "${ip}" == *:* ]]; then ip="[${ip}]"; fi
	echo "ss://${userinfo}@${ip}:${port}#ss-rust-$(hostname -s 2>/dev/null || echo srv)"
}

View_info(){
	[[ ! -f "${ss_config_file}" ]] && { echo -e "${Error} 未安装"; return; }
	local port method pwd ip4 ip6
	port=$(jq -r '.server_port' "${ss_config_file}")
	method=$(jq -r '.method' "${ss_config_file}")
	pwd=$(jq -r '.password' "${ss_config_file}")
	ip4=$(curl -4 -fsSL --max-time 5 https://api.ipify.org 2>/dev/null)
	ip6=$(curl -6 -fsSL --max-time 5 https://api64.ipify.org 2>/dev/null)
	echo
	echo "${SEP}"
	echo -e "  状态\t: $(systemctl is-active ss-rust 2>/dev/null)"
	echo -e "  端口\t: ${Green_font_prefix}${port}${Reset}"
	echo -e "  加密\t: ${Green_font_prefix}${method}${Reset}"
	echo -e "  密码\t: ${Green_font_prefix}${pwd}${Reset}"
	[[ -n "${ip4}" ]] && echo -e "  IPv4链接: ${Green_font_prefix}$(gen_ss_link "${ip4}" "${port}" "${method}" "${pwd}")${Reset}"
	[[ -n "${ip6}" ]] && echo -e "  IPv6链接: ${Green_font_prefix}$(gen_ss_link "${ip6}" "${port}" "${method}" "${pwd}")${Reset}"
	echo "${SEP}"
	echo -e "${Tip} 客户端要求支持 SS-AEAD-2017 (aes-*-gcm/chacha20-poly1305) 或 SS-2022。"
	echo
}

Self_update(){
	check_root
	echo -e "${Info} 从 ${SELF_UPDATE_URL} 拉取最新版 ..."
	local tmp; tmp=$(mktemp)
	safe_download "${SELF_UPDATE_URL}" "${tmp}" "${SELF_UPDATE_SHA256}" || { rm -f "${tmp}"; exit 1; }
	bash -n "${tmp}" || { echo -e "${Error} 新脚本语法检查失败，已放弃。"; rm -f "${tmp}"; exit 1; }
	install -m 0755 "${tmp}" "$0"
	rm -f "${tmp}"
	echo -e "${Info} 已更新，请重新执行。"
}

Menu(){
	clear
	echo -e "shadowsocks-rust 管理脚本 ${Green_font_prefix}v${sh_ver}${Reset}
  ${Green_font_prefix}1.${Reset}  安装
  ${Green_font_prefix}2.${Reset}  卸载
  ${SEP}
  ${Green_font_prefix}3.${Reset}  启动
  ${Green_font_prefix}4.${Reset}  停止
  ${Green_font_prefix}5.${Reset}  重启
  ${Green_font_prefix}6.${Reset}  查看状态
  ${SEP}
  ${Green_font_prefix}7.${Reset}  修改配置（端口/加密/密码）
  ${Green_font_prefix}8.${Reset}  查看连接信息
  ${SEP}
  ${Green_font_prefix}9.${Reset}  自更新脚本
  ${Green_font_prefix}0.${Reset}  退出"
	echo
	read -e -p "请选择 [0-9]:" n
	case "${n}" in
		1) Install_ss_rust ;;
		2) Uninstall_ss_rust ;;
		3) Start_ss_rust ;;
		4) Stop_ss_rust ;;
		5) Restart_ss_rust ;;
		6) Status_ss_rust ;;
		7) Modify_config ;;
		8) View_info ;;
		9) Self_update ;;
		0) exit 0 ;;
		*) echo -e "${Error} 无效选择" ;;
	esac
}

# 命令行参数
case "$1" in
	install)   Install_ss_rust ;;
	uninstall) Uninstall_ss_rust ;;
	start)     Start_ss_rust ;;
	stop)      Stop_ss_rust ;;
	restart)   Restart_ss_rust ;;
	status)    Status_ss_rust ;;
	config)    Modify_config ;;
	info)      View_info ;;
	update)    Self_update ;;
	"")        Menu ;;
	*) echo "Usage: $0 {install|uninstall|start|stop|restart|status|config|info|update}"; exit 1 ;;
esac
