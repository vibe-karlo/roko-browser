#!/bin/zsh
# Mirrors the iPhone's traffic over USB and logs connection starts and DNS only: hostnames and
# timing, no page contents. Stop it with Ctrl+C. Needs sudo, typed by the user.
sudo launchctl load -w /Library/Apple/System/Library/LaunchDaemons/com.apple.rpmuxd.plist 2>/dev/null
rvictl -s ${DEVICE:?set DEVICE to your iPhone id} || sudo rvictl -s ${DEVICE:?set DEVICE to your iPhone id}
ifconfig rvi0 >/dev/null || { echo "no rvi0: is the iPhone plugged in by USB?"; exit 1; }
sudo tcpdump -i rvi0 -n -s 2000 -U -G 3600 -w "${REAL_WORK:-$HOME/roko-real-sites}/real/work/cap-%H%M.pcap" 'udp port 53 or (tcp port 443 and (tcp[tcpflags] & tcp-syn != 0 or tcp[((tcp[12] & 0xf0) >> 2)] = 22)) or (udp port 443 and udp[8] & 0xc0 = 0xc0) or tcp port 53 or tcp port 853'
