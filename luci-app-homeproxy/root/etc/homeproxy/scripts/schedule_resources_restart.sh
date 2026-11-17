#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 延迟合并重启：资源库（china_ip4 / china_ip6 / gfw_list / china_list）更新
# 成功后会调用这里，而不是直接 /etc/init.d/homeproxy restart。
#
# 为什么要延迟 + 合并：
#   nft 的国内 IP 集合是在服务启动时按那几个 .txt 生成的，所以文件更新后必须
#   重启才生效；但界面上「检查更新」是一份一份调用的，若每份都立刻重启，连续
#   更新四份就会断流四次。这里开一个 5 秒的合并窗口：窗口内多次调用只记一次，
#   到点统一重启一次。
#
# 幂等：用标记文件表示「已排程」，重复调用直接退出。

export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

MARK="/var/run/homeproxy/restart.scheduled"
LOG="/var/run/homeproxy/homeproxy.log"

log() {
	mkdir -p "$(dirname "$LOG")" 2>/dev/null
	printf '%s [RESOURCES] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

mkdir -p "$(dirname "$MARK")" 2>/dev/null

if [ -e "$MARK" ]; then
	log "资源库已更新，重启已在排队（5 秒合并窗口内），本次不重复排程。"
	exit 0
fi

: > "$MARK" 2>/dev/null

log "资源库已更新，5 秒后重启服务使 nft 集合重建（期间多份更新会合并为一次重启）。"

# 脱管：忽略 SIGHUP，三处重定向，不占调用方的 fd。
(
	sleep 5
	rm -f "$MARK" 2>/dev/null
	/etc/init.d/homeproxy restart >/dev/null 2>&1
	log "重启完成，新资源已生效。"
) </dev/null >/dev/null 2>&1 &

exit 0
