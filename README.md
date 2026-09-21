# tm

Interactive tmux session manager for your terminal — local **and** remote.

`tm` shows every tmux session on your machine plus every session on any box
you have SSH key access to (via `~/.ssh/config`), and lets you attach, create,
and kill sessions across all of them from one place.

```
┌───────────────────────────────┐
│ tm - tmux session manager     │
└───────────────────────────────┘
Remote hosts: h134

               tmux sessions
┏━━━━┳━━━━━━━┳━━━━━━━━┳━━━━━━━━━┳━━━━━━━━━━┓
┃ #  ┃ Host  ┃ Name   ┃ Windows ┃ Attached ┃
┡━━━━╇━━━━━━━╇━━━━━━━━╇━━━━━━━━━╇━━━━━━━━━━┩
│ 1  │ local │ work   │    3    │   yes    │
│ 2  │ local │ scratch│    1    │    no    │
│ 3  │ h134  │ deploy │    2    │    no    │
└────┴───────┴────────┴─────────┴──────────┘

a=attach  n=new  k=kill  r=refresh  q=quit
```

## Features

- Lists local tmux sessions and sessions on every host in `~/.ssh/config`
- Remote hosts are scanned in parallel with short timeouts, so unreachable
  boxes don't slow you down
- Only key-based auth is used (`BatchMode=yes`) — no password prompts
- Attach to a remote session (`ssh -t <host> tmux attach ...`) or a local one
  (uses `switch-client` when you're already inside tmux)
- Create new sessions on any host
- Kill sessions anywhere, with confirmation
- Select sessions by number, name, or `host:name`

## Requirements

- Python 3.8+
- [rich](https://github.com/Textualize/rich) (`pip install rich`)
- tmux on the local machine and on any remote host you want to manage
- SSH key access to remote hosts, configured in `~/.ssh/config`

## Install

One-liner:

```sh
curl -fsSL https://raw.githubusercontent.com/MoarNachos/tm/main/install.sh | bash
```

Or manually:

```sh
git clone https://github.com/MoarNachos/tm.git
cd tm
pip install rich
install -m 755 tm ~/.local/bin/tm
```

Website: [viacopia.co/tmax](https://viacopia.co/tmax/)

## Usage

```sh
tm                # interactive UI, local + all remote hosts
tm local          # local sessions only
tm remote         # remote sessions only
tm ls             # list all sessions and exit
tm attach <name>  # attach directly (name or host:name)
tm update         # update tm to the latest version
tm help           # show help
```

Interactive keys:

- `a` — attach to a session (by #, name, or host:name)
- `n` — create a new session (pick a host)
- `k` — kill a session
- `r` — refresh the list
- `q` — quit

Remote hosts are discovered automatically from `Host` entries in
`~/.ssh/config` (wildcard entries are ignored). If a host is unreachable or
has no tmux server running, it's silently skipped.

## Load-balanced clusters

Some clusters assign you a random node each time you ssh in (e.g.
`ssh workcluster` lands on `workcluster-042`), so a tmux session started on
one node is invisible the next time you connect. If the cluster shares home
directories across nodes, `tm` can track your sessions for you.

List the cluster's ssh alias in `~/.config/tm/clusters`, one per line:

```
workcluster
```

Then:

- **Create** — when you create a session on the cluster, `tm` records the
  node's hostname in `~/.tm-nodes` (in the shared home) before starting tmux
- **List** — `tm` connects once, then checks every recorded node from inside
  the cluster; sessions show up as `workcluster/workcluster-042`
- **Attach / kill** — `tm` hops through the login node to the right node
  automatically (`ssh -t workcluster ssh -t workcluster-042 tmux attach`)
- **Cleanup** — nodes whose tmux server is gone are pruned from `~/.tm-nodes`
  on the next scan; unreachable nodes are kept (they might just be down)

Requires that nodes can ssh to each other (typical on shared-home clusters).
Sessions started outside `tm` are picked up too, as long as the node is in
`~/.tm-nodes` — or run `hostname >> ~/.tm-nodes` once from that node.

## License

MIT
