#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# 刷新一个「内置」规则集（bypass_mainland_china / gfwlist 模式下由生成器
# 直接 push 进配置、没有 uci ruleset 段的那些）。
#
# 设计约束（都是现场踩出来的）：
#   1. **先下载、后生效**。旧文件在下载成功前一动不动，失败时用户手上还是
#      能用的旧副本；只有拿到合法 SRS 之后才覆盖并重启内核。
#   2. **代理优先，拉不动就换路**。顺序是：经本地 mixed 代理 → 直连 →
#      jsdelivr 其它镜像（同样先代理后直连）。jsdelivr 的 fastly 节点在国内
#      时通时不通，单靠一条链路经常 30 秒超时。
#   3. **单次拉取 30 秒上限**，避免某个挂掉的镜像把整个按钮拖成几分钟。
#
# 用法：refresh_builtin_ruleset.sh <url> <目标路径> <代理> <tag> <rc文件>
#   代理为空表示跳过「经代理」这一跳。

export PATH="/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

url="$1"
path="$2"
proxy="$3"
tag="$4"
rc_file="$5"

LOG="/var/run/homeproxy/ruleset_download.log"
MAX=30

log() {
	mkdir -p "$(dirname "$LOG")" 2>/dev/null
	printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG" 2>/dev/null
}

fail() {
	log "内置规则集 $tag 刷新失败：$*"
	printf '1' > "$rc_file" 2>/dev/null
	rm -f "$tmp" 2>/dev/null
	exit 0
}

[ -n "$url" ] || fail "没有下载地址"
[ -n "$path" ] || fail "没有目标路径"

tmp="$path.new.$$"

# 下载一次并校验魔数；$2 非空则经代理。
try() {
	rm -f "$tmp" 2>/dev/null

	if [ -n "$2" ]; then
		curl -fsSL --connect-timeout 5 --max-time "$MAX" -x "$2" -o "$tmp" "$1" 2>/dev/null || return 1
	else
		curl -fsSL --connect-timeout 5 --max-time "$MAX" -o "$tmp" "$1" 2>/dev/null || return 1
	fi

	[ "$(head -c 3 "$tmp" 2>/dev/null)" = "SRS" ] || return 1
}

ok=0
used=""

if [ -n "$proxy" ]; then
	log "内置规则集 $tag：经代理 $proxy 下载（上限 ${MAX}s）"
	try "$url" "$proxy" && ok=1 && used="$url（代理）"
fi

if [ "$ok" != 1 ]; then
	log "内置规则集 $tag：代理不可用，改直连（上限 ${MAX}s）"
	try "$url" "" && ok=1 && used="$url（直连）"
fi

# 镜像兜底：同一个仓库在多个 jsdelivr 域名上，逐个试，仍然先代理后直连。
if [ "$ok" != 1 ]; then
	for host in gcore.jsdelivr.net cdn.jsdelivr.net testingcf.jsdelivr.net; do
		mirror="$(printf '%s' "$url" | sed "s#//fastly\.jsdelivr\.net/#//${host}/#")"
		[ "$mirror" = "$url" ] && continue

		[ -n "$proxy" ] && try "$mirror" "$proxy" && ok=1 && used="$mirror（代理）"
		[ "$ok" != 1 ] && try "$mirror" "" && ok=1 && used="$mirror（直连）"
		[ "$ok" = 1 ] && break
	done
fi

[ "$ok" = 1 ] || fail "代理、直连、镜像都没拿到合法 SRS"

mkdir -p "$(dirname "$path")" 2>/dev/null

if ! mv -f "$tmp" "$path" 2>/dev/null; then
	fail "无法写入 $path"
fi

log "内置规则集 $tag 已更新（$(wc -c < "$path" 2>/dev/null | tr -d ' ') 字节）来源=$used，重启服务使其生效"

/etc/init.d/homeproxy restart >/dev/null 2>&1
printf '0' > "$rc_file" 2>/dev/null
exit 0
