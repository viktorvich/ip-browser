# The server — what IP Browser installs and how to read every message

`Server/install.sh` is the whole server side. The app copies it to the server over SSH (a private temporary file of the login user) and runs it as root — directly, or through sudo with the password you typed; you can also run it yourself in your hosting provider's web console. It is idempotent: running `install` again keeps the server's keys and only adds a device.

```sh
# from the app (over SSH):           [sudo] bash /tmp/ip-browser-install.XXXXXX install --device <name> --pubkey '<ssh-ed25519 …>' --endpoint <address you typed>
# by hand in a web console:          curl -fsSLo ipb.sh https://raw.githubusercontent.com/viktorvich/ip-browser/installer-a49ff7d71a17/Server/install.sh && echo "a49ff7d71a17412a79cf09448dcd4e911f15e9112a20f74da64b443290f63010  ipb.sh" | sha256sum -c - && $(command -v sudo) bash ipb.sh install
# management (the app does these):   /usr/local/sbin/ip-browser-manage add-device --device <name> | list-devices | revoke-device --device <name> | status | uninstall
```

**Management is one command, not a shell.** The app's own SSH key is added with `restrict,command="/usr/local/sbin/ip-browser-manage --ssh"`: it can run the five verbs above and nothing else (no shell, no forwarding). If you installed as a sudo user, `/etc/sudoers.d/ip-browser` lets that user run exactly this command as root without a password — so adding and revoking devices works with an ordinary sudo policy, and the phone never gets a general root shell. The command runs a root-owned copy of the installer (`/usr/local/lib/ip-browser/install.sh`).

## What it puts on the server

| Part | What | Where |
|---|---|---|
| HOP | Hysteria 2.14.0 (official release, sha256 pinned), Salamander obfuscation, UDP 443, UDP 20000–29999 redirected to 443 (port hopping), self-signed certificate pinned by the app | `/usr/local/lib/ip-browser/hysteria`, `/etc/ip-browser/hysteria.yaml`, unit `ip-browser-hop` |
| XHTTP | Xray-core 26.11.9 (sha256 pinned): VLESS Encryption (ML-KEM-768) over XHTTP on 127.0.0.1 | `/usr/local/lib/ip-browser/xray`, `/etc/ip-browser/xray.json`, unit `ip-browser-xray` |
| Website front | Caddy 2.11.9 (sha256 pinned): a small static site on TCP 443 with a Let's Encrypt certificate for the server's IP (short-lived profile), proxying one secret path to XHTTP | `/etc/ip-browser/Caddyfile`, unit `ip-browser-web` |
| Port hopping | one nftables table `inet ip_browser` | unit `ip-browser-hop-ports` |
| Account | system user `ipbrowser`, no shell; services run with only `CAP_NET_BIND_SERVICE`. Everything root reads or runs (the nftables rules, the device secrets, the installer copy) belongs to root; `ipbrowser` only reads its own configuration and writes only Caddy's storage | `/etc/ip-browser` (root:ipbrowser 750), `/var/lib/ip-browser/caddy` |
| Management | the app's ed25519 key, restricted to the management command and tied to the device it was given with (comment `ip-browser:<device>`); `/usr/local/sbin/ip-browser-manage`; for a sudo user `/etc/sudoers.d/ip-browser` (that one command only) | `~/.ssh/authorized_keys` of the user who installed |
| Firewall | if ufw or firewalld is active: UDP 443, UDP 20000–29999 and, for XHTTP, TCP 443 and 80 — each opening recorded only if the installer added it (`/etc/ip-browser/added.*`); a HOP-only server closes the TCP openings it added | ufw / firewalld |

Exit policy, on both kinds: **IPv4 only**; private, reserved and local destinations refused; SMTP (TCP 25) refused; website names resolved by the server over DNS-over-HTTPS (1.1.1.1).

XHTTP needs the provider to let Let's Encrypt reach TCP port 80 for the certificate. If it cannot (NAT, closed port 80, another web server on 80/443), the server offers HOP only and the app says so.

## Messages, reasons and what to do

Every failure is reported as `@@error <code> <detail>`; the app shows the text below.

| Code | The app says | What to do |
|---|---|---|
| `dns` | The address does not exist. | Check the address; an IP address is the most reliable. |
| `timeout` | The server does not answer. | The server is off, the address/port is wrong, or your network does not reach it. Switch Wi-Fi ↔ mobile, or run the command in the provider's web console. |
| `unreachable` | There is no route to the server. | Same as above. |
| `refused` | The server answers, but SSH is closed on this port. | Use the SSH port from the provider's e-mail. |
| `reset` | The connection is cut while SSH starts. | The network closed SSH to this server: another network, or the web console. |
| `server_closed` | The server closed the connection after greeting. | The server itself refused: logins limited to some addresses or fail2ban. Wait 10 minutes or check the access settings. |
| `password_off` | The server does not accept password logins. | Reinstall the OS with a root password, or enable `PasswordAuthentication yes`. |
| `auth` | The server did not accept the login. | Check the user and the password. |
| `sudo`, `sudo_none` | sudo did not accept the password / this user may not use sudo. | Use root or an administrator. |
| `os`, `cpu` | This system / processor is not supported. | Ubuntu 20.04/22.04/24.04 or Debian 12/13, x86_64 or ARM64. |
| `disk` | No free disk space. | At least 300 MB. |
| `apt_busy` | The server is busy installing its own updates. | Wait a few minutes (the installer already waits up to 10). |
| `apt` | System packages could not be installed. | Mirrors unreachable: try later or reinstall the OS. |
| `no_internet` | The server cannot open github.com. | Ask the provider. |
| `download`, `checksum` | A download failed / did not match its checksum. | Try again; a mismatch means the download is altered on the way — nothing was installed. |
| `no_ipv4` | The server has no public IPv4 address. | A public IPv4 is required. |
| `port_busy` | UDP 443 is used by another program. | Use a clean server or remove that program. |
| `hop_start`, `core`, `firewall` | The connection service did not start. | The detail shows the server's own log line. |
| warning `web_ports_busy` | TCP 80/443 are taken: XHTTP is skipped. | Free the ports for the website front, or live with HOP only. |
| warning `no_certificate` | No certificate for the IP: XHTTP is skipped. | The provider closes port 80 or the server is behind NAT. |

After the installation the app checks each connection through its own door of the connection core. If none answers from your current network, it says so — for example *“UDP: no answer — UDP to the server does not get through from this network”* — and nothing goes out another way.

## Remove it

```sh
sudo /usr/local/sbin/ip-browser-manage uninstall     # or: sudo bash install.sh uninstall
# stops and removes the services and the nftables table, exactly the firewall openings and management keys
# the installer added (whoever runs the removal), the sudoers rule, the command, the files and the user
```

**Addresses.** The address you type in the app is the one phones dial; the server may leave to the internet from another
one (a VPS with two addresses, NAT). The website answers on both, each with its own Let's Encrypt certificate, and XHTTP is
offered only once the address phones dial serves it.

**Devices.** Revoking a device removes its connection access and, if that phone installed or reinstalled the server, its management key. The only device cannot be revoked (without a device the server has no user): `uninstall` removes everything instead. A phone that revokes itself loses its profile on that phone too. A reinstall from the same phone retires that phone's previous device and key (`--retire-device`, `--retire-key`), so no forgotten second access stays behind.

**Servers installed before 21.11.2026.** They kept no records. The first run of this installer there (a reinstall, or any management command) brings them up to date once: the app keys of that time, which could run any command and belong to no device, are removed (their phones keep their connection; to manage the server again a phone installs again, and the app says so); the firewall openings the old installer certainly made (UDP 443, the hop range, and TCP 443/80 when listed after them) are recorded as its own; an opening that may be the administrator's is kept, and `uninstall` names it (`"kept": [...]`).

**Tested** on clean Debian 12 and 13 guests by `Server/test/lifecycle.sh` (`tools/vm-test.sh`): an upgrade from the installer of 20.11.2026 by an ordinary sudo user, and a fresh install by root — keys, revocation rules, the HOP-only web front and a firewall after `uninstall` identical to before.
