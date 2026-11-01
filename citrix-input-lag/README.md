# Citrix input lag: periodic upstream freeze

Troubleshooting notes for a Citrix Workspace session where, roughly every 30 seconds, keyboard/mouse input stops reaching the VDI for ~5 seconds and then all of the buffered input executes at once. The screen keeps updating the whole time.

## Symptoms and findings so far

| Observation | What it tells us |
|---|---|
| Happens on several different VDIs | Not the VDIs; it's the client PC or the path to them |
| Wired connection, no VPN | Rules out Wi-Fi background scanning and VPN rekeying |
| Corporate environment: endpoint security, proxies | Security agents and inline inspection stay on the suspect list |
| Typing in local Notepad works fine during a freeze | Not a system-wide input stall on the PC; it's specific to the Citrix client or its traffic |
| `ping -t` to the Citrix gateway: no drops, steady latency | Basic network path is fine. ICMP doesn't prove UDP is clean, though |
| Another PC on the same network had no freezes | Machine-specific: client install, NIC/driver, or that machine's security config |
| Resource Monitor shows no CPU/disk spikes | Not a local process starving the Citrix client |
| Upstream bytes drop during the freeze but not to zero | Connection is alive (ACKs for incoming screen data still flow), but input is stuck behind something |

## Working theory

Head-of-line blocking on the upstream side. An outbound packet carrying input gets lost or held, everything behind it queues until it's retransmitted, and then the backlog is delivered at once. Retransmit timers that back off would explain the ~5 second wait.

Because it only happens on this PC, the likeliest causes are:

1. NIC offload features or the NIC driver mishandling certain outbound packets, possibly interacting with a security agent's network filter driver
2. The endpoint security stack on this machine inspecting or dropping the Citrix flow (especially UDP/EDT)
3. The installed Workspace app (version, corrupt per-user config, or App Protection's anti-keylogging in the input path)

## Things to try without admin rights

- **Check the transport.** Inside the VDI, run `ctxsession -v` and note whether it's UDP (EDT) or TCP.
- **Try the browser client.** Launch the desktop from the Citrix web portal in the browser (HTML5) instead of the Workspace app. If the freeze goes away, the installed client on this PC is involved.
- **Reset Workspace.** Workspace tray icon → Advanced Preferences → Reset Workspace. Re-add the store afterward.
- **Disable keyboard layout sync.** Workspace Preferences → Keyboard.
- **Record NIC settings.** Device Manager → network adapter → Advanced tab is viewable without admin. Note what's enabled for comparison with the good PC.
- **Compare versions.** Note the Workspace app version on this PC and on the good PC.

## Things that need admin / IT

- **Disable NIC offloads and power saving**, then test: Large Send Offload (v2, IPv4/IPv6), TCP/UDP Checksum Offload, Receive Side Coalescing / Packet Coalescing, Energy Efficient Ethernet / Green Ethernet. Also update the NIC driver.
- **Flip the transport as a test.** Force TCP (or UDP, if it's currently TCP). Client side: Workspace app Group Policy, Network routing → "Transport protocol for Citrix Workspace". Or the Citrix team can turn HDX adaptive transport off for a test.
- **Capture traffic during a freeze** with the built-in `pktmon` (admin prompt):
  ```
  pktmon start --capture --pkt-size 0 -f C:\temp\citrix.etl
  :: reproduce a few freezes
  pktmon stop
  pktmon etl2pcap C:\temp\citrix.etl -o C:\temp\citrix.pcapng
  ```
  In Wireshark: retransmissions or duplicate ACKs on the Citrix connection mean upstream packets are being lost. No outbound packets at all during the gap means something local is holding the data before it hits the wire.
- **Clean reinstall of Workspace** (uninstall, Citrix Receiver Clean-Up utility, reinstall the same version as the good PC).
- **Compare endpoint security config** between this PC and the good one (agent versions, policy groups, keystroke-protection/DLP features). Ask the Citrix team whether App Protection is enabled.

## Ticket text for IT

> Citrix input freezes for ~5s every ~30s on my PC only; another PC on the same network is fine. Local input and ping to the gateway are unaffected. Upstream traffic drops but doesn't stop during freezes. Transport is [UDP/TCP]. Please: (1) disable Large Send Offload / checksum offloads / Energy Efficient Ethernet on my NIC and update the driver, (2) test forcing TCP (or UDP) for Citrix, (3) capture traffic with pktmon during a freeze to look for retransmissions, (4) check whether my endpoint security config differs from [other PC].
