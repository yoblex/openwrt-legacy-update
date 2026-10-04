# openwrt-legacy-update

Миграция Xiaomi Redmi AX6S / Xiaomi AX3200 (`xiaomi,redmi-router-ax6s`) с OpenWrt ≤ 23.05 на 24.10+ с переносом конфигурации.

## Проблема

В 24.10 для этой платы изменена разметка NAND ([a6991fc](https://github.com/openwrt/openwrt/commit/a6991fc7d251f7ab65a588546e22abfd4f8ce472)): раздел `kernel` (4 MiB) заменён на `ubi-loader` (второй U-Boot), ядро и rootfs перенесены в UBI. Образы 24.10+ имеют `compat_version 2.0`, sysupgrade с 1.0 отклоняется:

```
Flash layout changes require a manual reinstall using factory.bin.
```

Переход: запись `factory.bin` в `kernel` и `ubi` через `mtd`. Конфигурация уничтожается.

## Требования

- Роутер: AX6S / AX3200 на OpenWrt ≤ 23.05, `compat_version 1.0`, SSH root.
- ПК: macOS или Linux, bash, OpenSSH ≥ 8.4, curl, python3.
- Подключение кабелем к LAN-порту.

## Использование

```sh
git clone https://github.com/yoblex/openwrt-legacy-update && cd openwrt-legacy-update
ROUTER=192.168.1.1 ./ax6s-migrate.sh check     # только чтение
ROUTER=192.168.1.1 ./ax6s-migrate.sh flash
ROUTER=192.168.1.1 ./ax6s-migrate.sh podkop    # опционально, нужен интернет на роутере
```

| Команда    | Действие |
|------------|----------|
| `check`    | плата, смещения и размеры `kernel`/`ubi`, бэд-блоки, `compat_version`, свободная RAM |
| `backup`   | `sysupgrade -b`, список пакетов, дамп всех mtd-разделов со сверкой sha256 |
| `firmware` | загрузка `factory.bin`, sha256, структура: FIT @ `0x0`, UBI @ `0x80000` |
| `flash`    | `check` → `backup` → `firmware` → запись → восстановление конфигурации → проверка |
| `podkop`   | последний релиз podkop, конвертация конфигурации 0.4.x → 0.7.x |

| Переменная    | По умолчанию             | |
|---------------|--------------------------|-|
| `ROUTER`      | `192.168.1.1`            | адрес роутера |
| `IFACE`       | авто                     | проводной интерфейс ПК (`en8`, `eth0`) |
| `VERSION`     | текущий stable           | ≥ 24.10 |
| `WORKDIR`     | `./work`                 | бэкапы, прошивки |
| `ROUTER_PASS` | запрос                   | пароль root |
| `YES`         | `0`                      | `1`: без подтверждения |
| `PODKOP_RU`   | `1`                      | русская локализация LuCI podkop |
| `BACKUP`      | `$WORKDIR/backup-latest` | источник конфигурации podkop |

## Перенос конфигурации

| Объект | Обработка |
|--------|-----------|
| `network`, `firewall` | без изменений |
| `dhcp` | удаляются хуки podkop (`server 127.0.0.42`, `noresolv`) |
| `wireless` | секции переносятся на новые radio по диапазону `2g`/`5g` |
| `system` | `compat_version 2.0` |
| root, SSH | хэш пароля root, host keys, `authorized_keys` |
| `rc.local`, crontab | crontab без строк podkop |

Пакеты не переносятся. Список: `work/backup-*/packages.txt`.

## podkop 0.4.x → 0.7.x

| 0.4.x | 0.7.x |
|-------|-------|
| `mode` | `connection_type` |
| `domain_list`, `subnets` | `community_lists` |
| `custom_domains_list_type`, `custom_domains`, `custom_domains_text` | `user_domain_list_type`, `user_domains`, `user_domains_text` |
| `custom_subnets_list_enabled`, `custom_subnets`, `custom_subnets_text` | `user_subnet_list_type`, `user_subnets`, `user_subnets_text` |
| `custom_local_domains` | `local_domain_lists` |
| `custom_download_domains`, `custom_download_subnets` | `remote_domain_lists`, `remote_subnet_lists` |
| `all_traffic_ip` | `fully_routed_ips` |
| `exclude_traffic_ip` | `settings.routing_excluded_ips` |
| `iface` | `settings.source_network_interfaces` |
| `dns_type`, `dns_server`, `dns_rewrite_ttl`, `update_interval`, `exclude_ntp` | `settings.*` |
| `quic_disable`, `yacd`, `ss_uot`, `socks5` | `settings.disable_quic`, `settings.enable_yacd`, `enable_udp_over_tcp`, `mixed_proxy_enabled` |

Удаляются: `split_dns_*`, `cache_file`, `detour`. `dont_touch_dhcp` = `0`: dnsmasq настраивает podkop.

Отдельно: `tools/convert.py podkop <old> <new>`.

## Реализация

- Запись на роутере отвязана от SSH-сессии через `trap "" HUP`, потому что в busybox нет `nohup`.
- Свежая система поднимается на `192.168.1.1/24`. Если ПК в другой сети с той же подсетью, IPv4 неоднозначен. Поэтому подключение после записи идёт по IPv6 link-local через `IFACE`: EUI-64 адрес `br-lan` от MAC не меняется. Резерв: опрос `ff02::1`, затем `192.168.1.1`.
- Host keys SSH не проверяются: до восстановления они другие.
- Скрипт останавливается до записи при любом несоответствии: плата, смещения, бэд-блоки, sha256, контрольная сумма загруженного образа.

## Известные особенности

- Заводской U-Boot считает неудачные загрузки (`flag_try_sys1_failed`, `flag_try_sys2_failed`) и через ~6 перезагрузок переводит роутер в soft-brick. Сброс счётчиков через `fw_setenv` в `rc.local` переносится, удалять его нельзя.
- В 25.12 менеджер пакетов `apk`.
- Пункт LuCI Services → Podkop может появиться только после повторного входа.

## Восстановление

| Состояние | Действие |
|-----------|----------|
| остановка до записи | роутер не изменён |
| нет связи после записи | кабель, `192.168.1.1`, root без пароля; конфигурация в `work/backup-*/sysupgrade.tar.gz` |
| не загружается | TFTP-восстановление Xiaomi со стоковой прошивкой; дампы разделов в `work/backup-*/mtd/`, калибровка Wi-Fi в `factory` |

## Проверено

| Устройство | Было | Стало | ПК |
|------------|------|-------|----|
| Redmi AX6S (RB01) | 23.05.4, podkop 0.4.11 | 25.12.5, podkop 0.7.22 | macOS |

Linux не проверялся.

## Ссылки

- [openwrt.org/toh/xiaomi/ax3200](https://openwrt.org/toh/xiaomi/ax3200)
- [openwrt/openwrt@a6991fc](https://github.com/openwrt/openwrt/commit/a6991fc7d251f7ab65a588546e22abfd4f8ce472)
- [itdoginfo/podkop](https://github.com/itdoginfo/podkop)

## Лицензия

MIT. Без гарантий; запись во флеш необратима.
