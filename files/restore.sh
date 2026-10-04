#!/bin/sh
# Runs on the freshly flashed router. Payload in /tmp/restore is built by tools/convert.py bundle.
R=/tmp/restore
EXPECT="$1"

# shellcheck disable=SC1091
. /etc/openwrt_release
case "$DISTRIB_RELEASE" in
"$EXPECT"*) ;;
*) echo "ABORT: running $DISTRIB_RELEASE, expected $EXPECT"; exit 1 ;;
esac

for f in network firewall dhcp system; do
	[ -f "$R/$f" ] && cp "$R/$f" "/etc/config/$f" && echo "config: $f"
done
[ -f "$R/wireless.sh" ] && sh "$R/wireless.sh"
for k in "$R"/dropbear_*_host_key; do
	[ -f "$k" ] && cp "$k" /etc/dropbear/ && chmod 600 "/etc/dropbear/${k##*/}" && echo "dropbear: ${k##*/}"
done
[ -f "$R/authorized_keys" ] && cp "$R/authorized_keys" /etc/dropbear/ && chmod 600 /etc/dropbear/authorized_keys && echo "dropbear: authorized_keys"
[ -f "$R/rc.local" ] && cp "$R/rc.local" /etc/rc.local && echo "rc.local"
[ -f "$R/crontab" ] && mkdir -p /etc/crontabs && cp "$R/crontab" /etc/crontabs/root && echo "crontab"
if [ -s "$R/root_hash" ]; then
	H=$(cat "$R/root_hash")
	sed -i "s|^root:[^:]*:|root:$H:|" /etc/shadow && echo "root password"
fi
uci set system.@system[0].compat_version='2.0'
uci commit system
sync
echo "compat_version=$(uci get system.@system[0].compat_version) lan=$(uci -q get network.lan.ipaddr)"
echo RESTORE_DONE
(sleep 3; reboot) >/dev/null 2>&1 </dev/null &
