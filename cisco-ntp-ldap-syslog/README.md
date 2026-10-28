# NTP, LDAP auth, fallback and syslog: Cisco ASA and NX-OS

Working notes. Addresses, DNs and names are placeholders. Syntax varies by
release, so check `?` on the box before pasting.

| Thing | Value |
|---|---|
| NTP servers | 10.0.0.10, 10.0.0.11 |
| LDAP / AD servers (LDAPS, TCP 636) | 10.0.0.20, 10.0.0.21 |
| Base DN | DC=example,DC=com |
| Bind (service) account | CN=svc-netauth,OU=Service,DC=example,DC=com |
| Admin AD group | CN=NetAdmins,OU=Groups,DC=example,DC=com |
| AD CA certificate | the root CA that issued the domain controllers' certs |
| Syslog collector | 10.0.0.30 (TLS 6514, TCP 1470, UDP 5514) |

## Before you start (both platforms)

- Keep a console session or an already-open SSH session while changing AAA.
  Don't log out until a new session authenticates.
- Make sure a local admin account exists and works (see "Fallback" below).
- Get NTP right first. LDAPS and syslog-over-TLS certificate checks fail if
  the clock is wrong.
- Use a dedicated, least-privilege bind account with a non-expiring password,
  and record where its password lives.
- List at least two domain controllers so one DC being down isn't an outage.

---

## Cisco ASA

### NTP

```
clock timezone EST -5
clock summer-time EDT recurring

ntp authentication-key 1 md5 <ntp-key>
ntp trusted-key 1
ntp authenticate
ntp server 10.0.0.10 key 1 source inside prefer
ntp server 10.0.0.11 key 1 source inside
```

- `source` is the interface name (nameif) used to reach the server.
- Newer releases also accept SHA-based keys instead of `md5`; check
  `ntp authentication-key 1 ?`.
- Drop the three key lines and `key 1` if your NTP servers don't use keys.

Verify: `show ntp associations` (a `*` means synced), `show ntp status`,
`show clock detail`.

### Trust the AD CA (for LDAPS and TLS syslog)

```
crypto ca trustpoint AD-CA
  enrollment terminal
  no ca-check
crypto ca authenticate AD-CA
! paste the CA certificate (PEM), then "quit"
```

Use the same trustpoint for syslog if the collector's certificate comes from
the same CA; otherwise make a second one.

### LDAP (LDAPS on 636) for management login

```
! Map AD group membership to an admin privilege level
ldap attribute-map NETADMINS
  map-name memberOf IETF-Radius-Service-Type
  map-value memberOf "CN=NetAdmins,OU=Groups,DC=example,DC=com" 6

aaa-server LDAP-AD protocol ldap
  max-failed-attempts 2
  reactivation-mode timed
  dead-time 5

aaa-server LDAP-AD (inside) host 10.0.0.20
  timeout 5
  server-port 636
  ldap-over-ssl enable
  ldap-base-dn DC=example,DC=com
  ldap-scope subtree
  ldap-naming-attribute sAMAccountName
  ldap-login-dn CN=svc-netauth,OU=Service,DC=example,DC=com
  ldap-login-password <bind-password>
  server-type microsoft
  ldap-attribute-map NETADMINS

aaa-server LDAP-AD (inside) host 10.0.0.21
  ! same sub-commands as above

aaa authorization exec authentication-server auto-enable
```

- `(inside)` is the interface used to reach the domain controllers.
- Service-Type values: 6 = Administrative (full access), 7 = NAS Prompt
  (limited), 5 = Outbound (no management access).
- `aaa authorization exec authentication-server` makes the ASA act on the
  mapped Service-Type; `auto-enable` puts admins straight into privileged mode.
- `timeout`, `max-failed-attempts`, `reactivation-mode` and `dead-time`
  control how fast the ASA gives up on a dead server and falls back to local.

The `aaa authentication` lines that turn this on are in the fallback section.

Test before relying on it:

```
test aaa-server authentication LDAP-AD host 10.0.0.20 username <admin-user> password <pw>
test aaa-server authentication LDAP-AD host 10.0.0.20 username <non-admin-user> password <pw>
debug ldap 255      ! turn off with: undebug all
```

Then open a new SSH session as an admin and as a non-admin. Confirm the
non-admin can't get privileged access; if they can, tighten the attribute
map or search scope.

### Fallback when LDAP/AD is down

```
username breakglass password <strong-password> privilege 15

aaa authentication ssh console LDAP-AD LOCAL
aaa authentication http console LDAP-AD LOCAL
aaa authentication serial console LOCAL
```

- How it behaves: the ASA tries LDAP first. It uses the local database
  **only when no LDAP server responds**. A wrong password or an unknown user
  in AD is a final rejection, not a reason to try local.
- Local-first isn't available here: the ASA can't check `LOCAL` and then
  fall back to a server group. LDAP-first with local fallback covers the
  "AD is down" case you're after.
- `serial console LOCAL` means the console always uses local accounts, so it
  works even if LDAP is up but misconfigured.
- Test it: block the LDAP servers (or point the group at an unused IP on a
  lab box) and confirm `breakglass` can log in via SSH.

### Syslog to a remote collector

```
logging enable
logging timestamp
logging device-id hostname
logging trap informational
logging buffered informational
logging permit-hostdown

! Preferred: TCP + TLS (needs the CA trustpoint above)
logging host inside 10.0.0.30 tcp/6514 secure

! TCP without TLS
logging host inside 10.0.0.31 tcp/1470

! UDP
logging host inside 10.0.0.32 udp/5514
```

- Format: `logging host <interface> <ip> tcp/<port>` or `udp/<port>`, so each
  destination gets its own port. TCP defaults to 1470; TCP ports can be
  1–65535 and UDP ports 1025–65535.
- `secure` adds TLS and only works with TCP. Newer releases can also check
  the collector's name in its certificate with
  `secure reference-identity <name>` (set up under `crypto ca reference-identity`).
- One transport per collector IP: a given host gets UDP or TCP, not both.
  To send the same logs over more than one transport, use separate
  collectors (or separate IPs on one collector).
- **`logging permit-hostdown` is important.** Without it, the ASA blocks new
  connections through the firewall whenever a TCP syslog server is
  unreachable.
- There's no automatic "try TLS, then TCP, then UDP" failover. Every
  configured host gets every message in parallel, so pick which ones you
  actually want.

Verify: `show logging` lists each host and whether TCP/TLS hosts are
connected. Entering and leaving config mode generates a message you can
look for on the collector.

---

## Cisco NX-OS (Nexus)

### NTP

```
clock timezone EST -5 0
clock summer-time EDT 2 Sunday March 02:00 1 Sunday November 02:00 60

ntp authentication-key 1 md5 <ntp-key> 0
ntp trusted-key 1
ntp authenticate
ntp server 10.0.0.10 key 1 use-vrf management prefer
ntp server 10.0.0.11 key 1 use-vrf management
ntp source-interface mgmt0
```

- `use-vrf management` when the servers are reached through mgmt0; use
  `use-vrf default` (or your VRF) for in-band.
- The trailing `0` means the key is entered in clear text.

Verify: `show ntp peer-status` (a `*` marks the synced server),
`show ntp peers`, `show clock`.

### Trust the AD CA (for LDAPS and TLS syslog)

```
crypto ca trustpoint AD-CA
crypto ca authenticate AD-CA
! paste the CA certificate (PEM), end with "END OF INPUT", confirm with "yes"
```

Check with `show crypto ca certificates`.

### LDAP (LDAPS on 636) for login

```
feature ldap

ldap-server timeout 5
ldap-server host 10.0.0.20 rootDN "CN=svc-netauth,OU=Service,DC=example,DC=com" password <bind-password> port 636
ldap-server host 10.0.0.20 enable-ssl
ldap-server host 10.0.0.21 rootDN "CN=svc-netauth,OU=Service,DC=example,DC=com" password <bind-password> port 636
ldap-server host 10.0.0.21 enable-ssl

ldap search-map ADMAP
  userprofile attribute-name "memberOf" search-filter "(&(objectClass=user)(sAMAccountName=$userid))" base-DN "DC=example,DC=com"

aaa group server ldap LDAP-AD
  server 10.0.0.20
  server 10.0.0.21
  ldap-search-map ADMAP
  use-vrf management
```

- `enable-ssl` turns on TLS to the server, and needs the AD CA trustpoint
  above. If logins fail with TLS errors on port 636, check whether your
  release does LDAPS or StartTLS with `enable-ssl`; StartTLS would mean
  port 389.

How roles get assigned:

- With `memberOf`, a user gets the NX-OS role whose name matches one of their
  AD group names. Simplest: an AD group called `network-admin` (or
  `network-operator` for read-only).
- To use your own group names, create a role with the same name on the
  switch (`role name NetAdmins` plus `rule` lines).
- Alternative: search on `description` instead, and set the user's AD
  description to `shell:roles="network-admin"`.
- A user who matches no role gets no useful access, so test a non-admin too.

Test and verify:

```
test aaa group LDAP-AD <username> <password>
show ldap-server
show ldap-server groups
show ldap-server statistics 10.0.0.20
show ldap-search-map
show aaa authentication
show user-account <username>      ! after logging in, check the role
```

### Fallback when LDAP/AD is down

```
username breakglass password <strong-password> role network-admin

aaa authentication login default group LDAP-AD local
aaa authentication login default fallback error local
aaa authentication login console local
```

- How it behaves: the switch tries LDAP first and uses local accounts **only
  when no LDAP server responds**. A wrong password or unknown user is a
  final rejection.
- Local-first: I couldn't find a supported way to check local accounts
  before the LDAP group on NX-OS. LDAP-first with local fallback covers the
  "AD is down" case.
- `login console local` means the console always uses local accounts.
- `ldap-server timeout` controls how long the switch waits before treating a
  server as down; keep it short so fallback is quick.
- Test it: make the LDAP servers unreachable (or point the group at an
  unused IP on a lab box) and confirm `breakglass` can log in over SSH.

### Syslog to a remote collector

```
logging timestamp milliseconds
logging source-interface mgmt0

! Preferred: TCP + TLS (needs a trustpoint for the collector's CA)
logging server 10.0.0.30 6 secure port 6514 use-vrf management

! UDP
logging server 10.0.0.32 6 port 5514 use-vrf management
```

- The `6` is the severity (informational); each server gets its own `port`.
- `secure` sends over TCP with TLS (default port 6514).
- **Plain TCP without TLS:** I couldn't find an option for it on NX-OS. It
  offers UDP or TLS. If you need plain TCP, relay through a local syslog
  server (rsyslog, syslog-ng) that receives UDP and forwards over TCP.
- Like the ASA, there's no transport failover: every configured server gets
  every message.

Verify: `show logging server` shows each server, port and whether it's
secure. Entering and leaving config mode generates a message to look for on
the collector.

---

## Break-glass accounts

- Same local account on every device, strong unique password per device if
  you can manage it, stored in your secrets manager.
- Rotate it after every use.
- Alert on it: search syslog for logins by `breakglass`. Any use while AD is
  up is worth investigating.

## Rollout checklist

1. NTP configured and synced.
2. AD CA trustpoint installed.
3. Break-glass local account created and tested.
4. LDAP config applied, `test` commands pass for an admin and a non-admin.
5. AAA login lines applied, console kept on local.
6. New session logs in as admin with the right privileges; non-admin is denied.
7. Fallback tested: with LDAP unreachable, break-glass can log in.
8. Syslog hosts configured; test messages arrive over each transport.
9. Save config (`write memory` on ASA, `copy run start` on NX-OS).
10. Only then close the original session.
