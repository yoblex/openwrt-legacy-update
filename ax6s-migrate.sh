#!/usr/bin/env bash
# Xiaomi Redmi AX6S / Xiaomi AX3200: OpenWrt <= 23.05 (legacy flash layout) -> 24.10+ (UBI layout).
# shellcheck disable=SC2016  # single-quoted commands are expanded on the router
set -uo pipefail

ROUTER=${ROUTER:-192.168.1.1}
VERSION=${VERSION:-}
IFACE=${IFACE:-}
WORKDIR=${WORKDIR:-$PWD/work}
YES=${YES:-0}
PODKOP_RU=${PODKOP_RU:-1}

BOARD=xiaomi,redmi-router-ax6s
PROFILE=xiaomi_redmi-router-ax6s
TARGET=mediatek/mt7622
DL=https://downloads.openwrt.org
KERNEL_OFFSET=2883584   # 0x2c0000
KERNEL_SIZE=4194304     # 0x400000
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
INFO="" LL="" BK="" NEW=""

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing: $c"; done; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
kv() { printf '%s\n' "$INFO" | sed -n "s/^$1=//p" | head -1; }

init_ssh() {
	need ssh curl python3 tar
	local v
	v=$(ssh -V 2>&1 | sed -n 's/^OpenSSH_\([0-9]*\)\.\([0-9]*\).*/\1\2/p')
	[ "${v:-0}" -ge 84 ] || die "OpenSSH >= 8.4 required"
	if [ -z "${ROUTER_PASS+x}" ]; then
		read -rsp "root password for $ROUTER (empty if none): " ROUTER_PASS
		echo >&2
	fi
	export ROUTER_PASS
	printf '#!/bin/sh\nprintf "%%s\\n" "$ROUTER_PASS"\n' >"$TMP/askpass"
	chmod 700 "$TMP/askpass"
}

# rsh HOST CMD... (stdin is forwarded). Host keys change on reflash, so they are not pinned.
rsh() {
	local h=$1
	shift
	SSH_ASKPASS="$TMP/askpass" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
		ssh -T -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
		-o ConnectTimeout="${CT:-10}" -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
		-o PreferredAuthentications=publickey,password,keyboard-interactive -o NumberOfPasswordPrompts=1 \
		"root@$h" "$@"
}
r() { rsh "$@" </dev/null 2>/dev/null; }
probe() { CT=5 r "$1" '. /etc/openwrt_release; echo "$DISTRIB_RELEASE $(cat /tmp/sysinfo/board_name)"'; }

detect_iface() {
	[ -n "$IFACE" ] && return 0
	if [ "$(uname)" = Darwin ]; then
		IFACE=$(route -n get "$ROUTER" 2>/dev/null | awk '/interface:/{print $2}')
	else
		IFACE=$(ip route get "$ROUTER" 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1)
	fi
	[ -n "$IFACE" ] || die "cannot detect interface towards $ROUTER, set IFACE="
	case "$IFACE" in utun* | tun* | wg* | ppp*) die "route to $ROUTER goes via VPN ($IFACE), set IFACE= to the wired interface" ;; esac
	log "interface: $IFACE"
}

own_ll() {
	if command -v ifconfig >/dev/null 2>&1; then
		ifconfig "$IFACE" 2>/dev/null | awk '/inet6 fe80/{print $2}' | cut -d% -f1 | head -1
	else
		ip -6 addr show dev "$IFACE" scope link | awk '/inet6/{print $2}' | cut -d/ -f1 | head -1
	fi
}

ll_neighbours() {
	if [ "$(uname)" = Darwin ]; then
		ping6 -c 2 -i 1 -I "$IFACE" ff02::1 2>/dev/null
	else
		ping -6 -c 2 -i 1 -I "$IFACE" ff02::1 2>/dev/null
	fi | sed -n 's/.*from \(fe80::[0-9a-f:]*\).*/\1/p' | sort -u
}

cmd_check() {
	INFO=$(rsh "$ROUTER" '
		. /etc/openwrt_release
		echo "release=$DISTRIB_RELEASE"
		echo "board=$(cat /tmp/sysinfo/board_name 2>/dev/null)"
		echo "model=$(cat /tmp/sysinfo/model 2>/dev/null)"
		echo "compat=$(uci -q get system.@system[0].compat_version)"
		for p in kernel ubi ubi-loader; do
			d=$(grep "\"$p\"$" /proc/mtd | cut -d: -f1)
			[ -n "$d" ] && echo "mtd.$p=$d $(cat /sys/class/mtd/$d/offset) $(cat /sys/class/mtd/$d/size) $(cat /sys/class/mtd/$d/bad_blocks)"
		done
		echo "tmpfree=$(df -k /tmp | awk "NR==2{print \$4}")"
		echo "ll=$(ip -6 addr show dev br-lan scope link 2>/dev/null | awk "/inet6/{print \$2}" | cut -d/ -f1 | head -1)"
	' </dev/null) || die "ssh root@$ROUTER failed"
	log "$(kv model) | board $(kv board) | OpenWrt $(kv release) | compat_version $(kv compat)"

	local kdev koff ksize kbad udev uoff ubad
	[ "$(kv board)" = "$BOARD" ] || die "unsupported board '$(kv board)', expected $BOARD"
	[ -z "$(kv mtd.ubi-loader)" ] || die "already on UBI layout (ubi-loader present): use regular sysupgrade"
	read -r kdev koff ksize kbad <<<"$(kv mtd.kernel)"
	read -r udev uoff _ ubad <<<"$(kv mtd.ubi)"
	[ -n "$kdev" ] && [ -n "$udev" ] || die "partitions 'kernel'/'ubi' not found"
	[ "$koff" = "$KERNEL_OFFSET" ] && [ "$ksize" = "$KERNEL_SIZE" ] && [ "$uoff" = $((KERNEL_OFFSET + KERNEL_SIZE)) ] ||
		die "unexpected layout: kernel $koff+$ksize, ubi $uoff"
	[ "$kbad" = 0 ] && [ "$ubad" = 0 ] || die "bad blocks in kernel/ubi ($kbad/$ubad): mtd write would shift data"
	case "$(kv compat)" in "" | 1.0) ;; *) die "compat_version $(kv compat), expected 1.0" ;; esac
	[ "$(kv tmpfree)" -gt 30000 ] || die "not enough free RAM in /tmp"
	LL=$(kv ll)
	log "layout: kernel=$kdev ubi=$udev, bad blocks 0, link-local ${LL:-n/a}"
	log "check: OK"
}

cmd_backup() {
	BK="$WORKDIR/backup-$(date +%Y%m%d-%H%M%S)"
	mkdir -p "$BK/mtd"
	rsh "$ROUTER" 'sysupgrade -b - 2>/dev/null' </dev/null >"$BK/sysupgrade.tar.gz"
	tar tzf "$BK/sysupgrade.tar.gz" >/dev/null 2>&1 || die "sysupgrade -b failed"
	r "$ROUTER" 'command -v apk >/dev/null && apk list --installed || opkg list-installed' >"$BK/packages.txt"
	local dev name rs
	while read -r dev name; do
		rsh "$ROUTER" "cat /dev/${dev}ro" </dev/null >"$BK/mtd/$dev-$name.bin"
		rs=$(r "$ROUTER" "sha256sum /dev/${dev}ro" | cut -d' ' -f1)
		[ "$rs" = "$(sha256 "$BK/mtd/$dev-$name.bin")" ] || log "WARNING: $dev-$name checksum differs (partition changed while reading)"
	done <<<"$(r "$ROUTER" "sed -n 's/^\(mtd[0-9]*\): [0-9a-f]* [0-9a-f]* \"\(.*\)\"$/\1 \2/p' /proc/mtd")"
	ln -sfn "$(basename "$BK")" "$WORKDIR/backup-latest"
	log "backup: $BK ($(find "$BK/mtd" -name '*.bin' | wc -l | tr -d ' ') partitions)"
}

cmd_firmware() {
	need curl python3
	[ -n "$VERSION" ] || VERSION=$(curl -fsS "$DL/.versions.json" | python3 -c 'import json,sys;print(json.load(sys.stdin)["stable_version"])') ||
		die "cannot resolve stable version"
	case "$VERSION" in 2[4-9].* | [3-9][0-9].*) ;; *) die "VERSION=$VERSION: 24.10 or newer required" ;; esac
	FW_DIR="$WORKDIR/firmware-$VERSION"
	FACTORY="openwrt-$VERSION-${TARGET/\//-}-$PROFILE-factory.bin"
	mkdir -p "$FW_DIR"
	local base="$DL/releases/$VERSION/targets/$TARGET"
	curl -fsS "$base/sha256sums" | grep -E " \*?$FACTORY\$" >"$FW_DIR/sha256sums" || die "$FACTORY not found in $base"
	FW_SHA=$(cut -d' ' -f1 "$FW_DIR/sha256sums")
	[ -f "$FW_DIR/$FACTORY" ] && [ "$(sha256 "$FW_DIR/$FACTORY")" = "$FW_SHA" ] ||
		curl -fsS -o "$FW_DIR/$FACTORY" "$base/$FACTORY" || die "download failed"
	[ "$(sha256 "$FW_DIR/$FACTORY")" = "$FW_SHA" ] || { rm -f "$FW_DIR/$FACTORY"; die "sha256 mismatch"; }
	# factory.bin = ubi-loader FIT padded to 512 KiB + UBI image
	[ "$(od -An -tx1 -N4 "$FW_DIR/$FACTORY" | tr -d ' \n')" = d00dfeed ] || die "factory.bin: no FIT header at 0x0"
	[ "$(od -An -c -j 524288 -N4 "$FW_DIR/$FACTORY" | tr -d ' \n')" = 'UBI#' ] || die "factory.bin: no UBI header at 0x80000"
	log "firmware: $FACTORY, sha256 OK"
}

cmd_flash() {
	detect_iface
	cmd_check
	cmd_backup
	cmd_firmware

	rm -rf "$TMP/src" "$TMP/restore"
	mkdir -p "$TMP/src"
	tar xzf "$BK/sysupgrade.tar.gz" -C "$TMP/src" || die "cannot extract backup"
	log "restore payload:"
	python3 "$HERE/tools/convert.py" bundle "$TMP/src" "$TMP/restore" >&2 || die "convert failed"
	cp "$HERE/files/restore.sh" "$TMP/restore/"

	cat >&2 <<EOF

  Flash $FACTORY to $ROUTER ($(kv model), OpenWrt $(kv release))
  - partitions 'kernel' and 'ubi' are overwritten; installed packages are lost
  - network, wireless, dhcp, firewall, system, root password, SSH keys are restored
  - do not power off the router until this script finishes

EOF
	if [ "$YES" != 1 ]; then
		read -rp "type 'yes' to flash: " a
		[ "$a" = yes ] || die "aborted"
	fi

	log "upload factory.bin"
	rsh "$ROUTER" 'cat > /tmp/factory.bin' <"$FW_DIR/$FACTORY" || die "upload failed"
	[ "$(r "$ROUTER" 'sha256sum /tmp/factory.bin' | cut -d' ' -f1)" = "$FW_SHA" ] || die "uploaded file checksum mismatch"

	log "flashing"
	r "$ROUTER" '( trap "" HUP PIPE; sh -c "mount -o remount,ro / 2>&1; mount -o remount,ro /overlay 2>&1; cd /tmp; dd if=factory.bin bs=1M count=4 2>/dev/null | mtd write - kernel && echo KERNEL_WRITE_OK && dd if=factory.bin bs=1M skip=4 2>/dev/null | mtd -r write - ubi; echo MTD_EXIT=\$?" ) > /tmp/flash.log 2>&1 </dev/null & echo started' |
		grep -q started || die "could not start flash"
	local out fails=0 i
	for i in $(seq 1 100); do
		sleep 3
		if out=$(CT=5 r "$ROUTER" 'cat /tmp/flash.log'); then
			fails=0
			case "$out" in
			*MTD_EXIT=[1-9]*) die "mtd write failed; router still runs the old system from RAM, do NOT reboot it. Log: $out" ;;
			*"not found"*) [[ "$out" == *KERNEL_WRITE_OK* ]] || die "flash command did not start: $out" ;;
			esac
		else
			fails=$((fails + 1))
			[ $fails -ge 3 ] && break
		fi
	done
	[ $fails -ge 3 ] || die "router did not reboot after flashing, check it manually"
	log "written, router is rebooting"

	# The fresh system comes up on 192.168.1.1, which may collide with another network on this host.
	# IPv6 link-local over the wired interface avoids that.
	sleep 20
	local c me
	for i in $(seq 1 60); do
		me=$(own_ll)
		for c in ${LL:+$LL%$IFACE} $(ll_neighbours | grep -vx "${me:-x}" | sed "s/\$/%$IFACE/") 192.168.1.1; do
			[ "$(probe "$c")" = "$VERSION $BOARD" ] && { NEW=$c; break 2; }
		done
		[ $((i % 6)) -eq 0 ] && log "waiting for OpenWrt $VERSION..."
		sleep 5
	done
	[ -n "$NEW" ] || die "fresh system not reachable; connect by cable to 192.168.1.1 and restore $BK/sysupgrade.tar.gz manually"
	log "OpenWrt $VERSION is up at $NEW"

	COPYFILE_DISABLE=1 tar --format=ustar -cf - -C "$TMP/restore" . |
		rsh "$NEW" 'rm -rf /tmp/restore; mkdir -p /tmp/restore && tar xf - -C /tmp/restore' || die "payload upload failed"
	out=$(r "$NEW" "sh /tmp/restore/restore.sh '$VERSION'")
	printf '%s\n' "$out" | sed 's/^/  router: /' >&2
	[[ "$out" == *RESTORE_DONE* ]] || die "restore failed, router is reachable at $NEW"

	local lan
	lan=$(printf '%s\n' "$out" | sed -n 's/.* lan=\([0-9.]*\).*/\1/p')
	lan=${lan:-$ROUTER}
	log "rebooting with restored config, waiting for $lan"
	sleep 20
	for i in $(seq 1 60); do
		[ "$(probe "$lan")" = "$VERSION $BOARD" ] && break
		sleep 5
	done
	r "$lan" '. /etc/openwrt_release; echo "OpenWrt $DISTRIB_RELEASE, compat_version $(uci get system.@system[0].compat_version)"
		echo "wan: $(ifstatus wan | jsonfilter -e "@[\"ipv4-address\"][0].address")"
		ping -c1 -W3 1.1.1.1 >/dev/null && echo "internet: ok" || echo "internet: FAIL"
		iwinfo 2>/dev/null | grep ESSID' >&2 ||
		log "not reachable at $lan yet: renew DHCP on $IFACE or use ${LL:-<link-local>}%$IFACE"
	log "done. backup: $BK"
	log "packages from the old system: $BK/packages.txt (podkop: $0 podkop)"
}

cmd_podkop() {
	local bk="${BACKUP:-$WORKDIR/backup-latest}" ext rel urls u
	r "$ROUTER" 'ping -c1 -W3 1.1.1.1 >/dev/null' || die "router $ROUTER has no internet access"
	if r "$ROUTER" 'command -v apk >/dev/null'; then ext=apk; else ext=ipk; fi
	rel=$(curl -fsS https://api.github.com/repos/itdoginfo/podkop/releases/latest) || die "GitHub API request failed"
	urls=$(printf '%s' "$rel" | python3 -c 'import json,sys;[print(a["browser_download_url"]) for a in json.load(sys.stdin)["assets"]]' |
		grep -E "/(podkop|luci-app-podkop|luci-i18n-podkop-ru)[-_][^/]*\.$ext\$")
	[ "$PODKOP_RU" = 1 ] || urls=$(printf '%s\n' "$urls" | grep -v i18n)
	[ -n "$urls" ] || die "no .$ext assets in the latest podkop release"
	mkdir -p "$TMP/pk"
	r "$ROUTER" 'rm -rf /tmp/pk; mkdir -p /tmp/pk'
	for u in $urls; do
		curl -fsSL -o "$TMP/pk/${u##*/}" "$u" || die "download failed: $u"
		rsh "$ROUTER" "cat > /tmp/pk/${u##*/}" <"$TMP/pk/${u##*/}" || die "upload failed"
		log "package: ${u##*/}"
	done
	if [ $ext = apk ]; then
		rsh "$ROUTER" 'apk update >/dev/null && apk add --allow-untrusted /tmp/pk/podkop-*.apk /tmp/pk/luci-*.apk' </dev/null | tail -3 >&2
	else
		rsh "$ROUTER" 'opkg update >/dev/null && opkg install /tmp/pk/podkop*.ipk && opkg install /tmp/pk/luci-*.ipk' </dev/null | tail -3 >&2
	fi
	r "$ROUTER" 'command -v podkop >/dev/null' || die "podkop installation failed"

	mkdir -p "$TMP/pk-src"
	if [ -f "$bk/sysupgrade.tar.gz" ] && tar xzf "$bk/sysupgrade.tar.gz" -C "$TMP/pk-src" etc/config/podkop 2>/dev/null; then
		if grep -q "^config settings" "$TMP/pk-src/etc/config/podkop"; then
			cp "$TMP/pk-src/etc/config/podkop" "$TMP/podkop.new"
		else
			python3 "$HERE/tools/convert.py" podkop "$TMP/pk-src/etc/config/podkop" "$TMP/podkop.new" >&2 || die "podkop config conversion failed"
		fi
		rsh "$ROUTER" 'cp /etc/config/podkop /etc/config/podkop.default; cat > /etc/config/podkop && chmod 600 /etc/config/podkop' <"$TMP/podkop.new" ||
			die "config upload failed"
		log "podkop config migrated from $bk"
	else
		log "no podkop config in backup: configure it in LuCI -> Services -> Podkop"
	fi
	r "$ROUTER" '/etc/init.d/podkop enable; /etc/init.d/podkop restart; rm -f /tmp/luci-indexcache* /tmp/luci-modulecache/*; /etc/init.d/rpcd restart; rm -rf /tmp/pk'
	sleep 10
	r "$ROUTER" 'echo "podkop $(podkop show_version), $(sing-box version | head -1)"
		pgrep sing-box >/dev/null && echo "sing-box: running" || echo "sing-box: NOT running"
		echo "dnsmasq upstream: $(uci -q get dhcp.@dnsmasq[0].server)"' >&2
}

usage() {
	cat <<EOF
usage: $0 <command>

  check     read-only preflight: board, layout, bad blocks
  backup    sysupgrade backup + raw dump of all mtd partitions to \$WORKDIR
  firmware  download and verify factory.bin
  flash     check + backup + firmware + flash + restore config
  podkop    install latest podkop and migrate its config from the backup

env: ROUTER=$ROUTER IFACE=<auto> VERSION=<stable> WORKDIR=$WORKDIR
     ROUTER_PASS=<prompt> YES=0 PODKOP_RU=1 BACKUP=\$WORKDIR/backup-latest
EOF
}

case "${1:-}" in
check) init_ssh; detect_iface; cmd_check ;;
backup) init_ssh; cmd_backup ;;
firmware) cmd_firmware ;;
flash) init_ssh; cmd_flash ;;
podkop) init_ssh; cmd_podkop ;;
*) usage; exit 1 ;;
esac
