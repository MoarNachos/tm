#!/usr/bin/env python3
"""tm - interactive tmux session manager, local and remote.

Lists tmux sessions on this machine and on every host in your
~/.ssh/config that you have key access to, and lets you attach,
create, and kill sessions anywhere from one place.
"""

import os
import re
import shlex
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

from rich.console import Console
from rich.table import Table
from rich.prompt import Prompt, Confirm
from rich.panel import Panel
from rich.text import Text


console = Console()

LOCAL = "local"
SSH_OPTS = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=3"]
LIST_FORMAT = "#{session_name}\t#{session_windows}\t#{session_attached}"
PATH_PREFIX = 'PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin" '
CLUSTERS_PATH = os.path.expanduser("~/.config/tm/clusters")
NODES_FILE = "$HOME/.tm-nodes"


def ssh_config_hosts():
    """Return Host aliases from ~/.ssh/config (first alias per entry, no wildcards)."""
    path = os.path.expanduser("~/.ssh/config")
    hosts = []
    try:
        with open(path) as f:
            for line in f:
                m = re.match(r"^\s*Host\s+(.+)", line, re.IGNORECASE)
                if not m:
                    continue
                for alias in m.group(1).split():
                    if not any(c in alias for c in "*?!"):
                        hosts.append(alias)
                        break
    except OSError:
        pass
    return hosts


def cluster_hosts():
    """Return ssh aliases listed in ~/.config/tm/clusters (load-balanced clusters)."""
    try:
        with open(CLUSTERS_PATH) as f:
            return [ln.strip() for ln in f
                    if ln.strip() and not ln.strip().startswith("#")]
    except OSError:
        return []


def tmux_cmd(host, args, node=None):
    """Build a tmux command for local, a remote host, or a node inside a cluster."""
    if host == LOCAL:
        return ["tmux"] + args
    # Quote for the remote shell so tmux format strings (#{...}) survive.
    # Non-interactive ssh often has a minimal PATH, so add common tmux locations.
    remote = " ".join(shlex.quote(a) for a in ["tmux"] + args)
    remote = PATH_PREFIX + remote
    if node:
        # Two-hop: ssh to the cluster's login node, then to the recorded node.
        remote = ("ssh -o BatchMode=yes -o ConnectTimeout=3 "
                  f"{shlex.quote(node)} {shlex.quote(remote)}")
    return ["ssh"] + SSH_OPTS + [host, remote]


def get_sessions(host):
    """Get tmux sessions on a host. Returns (sessions, error)."""
    try:
        result = subprocess.run(
            tmux_cmd(host, ["list-sessions", "-F", LIST_FORMAT]),
            capture_output=True, text=True, timeout=8,
        )
    except subprocess.TimeoutExpired:
        return [], "timed out"
    if result.returncode != 0:
        err = result.stderr.strip().splitlines()
        err = err[-1] if err else f"exit code {result.returncode}"
        # No tmux server / no sessions is a normal state, not an error
        if ("no server running" in err
                or "no sessions" in err.lower()
                or ("error connecting to" in err and "No such file or directory" in err)):
            return [], None
        return [], err
    sessions = []
    for line in result.stdout.strip().splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            sessions.append({
                "host": host,
                "name": parts[0],
                "windows": parts[1],
                "attached": "yes" if parts[2] == "1" else "no",
            })
    return sessions, None


def cluster_list_script():
    """Shell script run on a cluster login node: list sessions on every node
    recorded in ~/.tm-nodes, and prune nodes whose tmux server is gone."""
    inner = PATH_PREFIX + f'tmux list-sessions -F "{LIST_FORMAT}"'
    return (
        f'F="{NODES_FILE}"; [ -f "$F" ] || exit 0; keep=""; '
        'for n in $(sort -u "$F"); do '
        f"out=$(ssh -o BatchMode=yes -o ConnectTimeout=3 \"$n\" '{inner}' 2>&1); "
        'if [ $? -eq 0 ]; then keep="$keep $n"; '
        'printf \'%s\\n\' "$out" | sed "s/^/$n\t/"; '
        "elif printf '%s' \"$out\" | "
        "grep -qiE 'no server running|no sessions|error connecting to'; then :; "
        'else keep="$keep $n"; fi; '
        'done; printf \'%s\\n\' $keep > "$F"'
    )


def get_cluster_sessions(alias):
    """Get tmux sessions on all recorded nodes of a cluster. Returns (sessions, error)."""
    try:
        result = subprocess.run(
            ["ssh"] + SSH_OPTS + [alias, cluster_list_script()],
            capture_output=True, text=True, timeout=25,
        )
    except subprocess.TimeoutExpired:
        return [], "timed out"
    if result.returncode != 0:
        err = result.stderr.strip().splitlines()
        err = err[-1] if err else f"exit code {result.returncode}"
        return [], err
    sessions = []
    for line in result.stdout.strip().splitlines():
        parts = line.split("\t")
        if len(parts) == 4:
            sessions.append({
                "host": alias,
                "node": parts[0],
                "name": parts[1],
                "windows": parts[2],
                "attached": "yes" if parts[3] == "1" else "no",
            })
    return sessions, None


def get_all_sessions(hosts, clusters=(), include_local=True):
    """Fetch sessions from local + all hosts in parallel. Returns (sessions, errors)."""
    targets = ([LOCAL] if include_local else []) + hosts + list(clusters)
    if not targets:
        return [], []

    def fetch(host):
        if host in clusters:
            return get_cluster_sessions(host)
        return get_sessions(host)

    with ThreadPoolExecutor(max_workers=min(len(targets), 16)) as pool:
        results = pool.map(fetch, targets)
    sessions, errors = [], []
    for host, (host_sessions, error) in zip(targets, results):
        sessions.extend(host_sessions)
        if error:
            errors.append((host, error))
    return sessions, errors


def display_sessions(sessions):
    table = Table(title="tmux sessions", border_style="blue", show_lines=False)
    table.add_column("#", style="dim", width=4)
    table.add_column("Host", style="magenta")
    table.add_column("Name", style="cyan bold")
    table.add_column("Windows", justify="center")
    table.add_column("Attached", justify="center")

    for i, s in enumerate(sessions, 1):
        attached_style = "green" if s["attached"] == "yes" else "dim"
        host = s["host"] + (f"/{s['node']}" if s.get("node") else "")
        table.add_row(
            str(i), host, s["name"], s["windows"],
            Text(s["attached"], style=attached_style),
        )
    console.print(table)


def attach_session(session):
    host, name = session["host"], session["name"]
    if host == LOCAL:
        if "TMUX" in os.environ:
            subprocess.run(["tmux", "switch-client", "-t", name])
        else:
            subprocess.run(["tmux", "attach-session", "-t", name])
    else:
        remote = PATH_PREFIX + f"tmux attach-session -t {shlex.quote(name)}"
        if session.get("node"):
            # Hop through the cluster's login node to the node holding the session.
            remote = (f"ssh -t -o BatchMode=yes -o ConnectTimeout=3 "
                      f"{shlex.quote(session['node'])} {shlex.quote(remote)}")
        subprocess.run(["ssh", "-t"] + SSH_OPTS + [host, remote])


def create_session(hosts, clusters=()):
    name = Prompt.ask("[cyan]Session name[/]")
    if not name.strip():
        console.print("[red]No name given, cancelled.[/]")
        return
    host = LOCAL
    choices = [LOCAL] + hosts + list(clusters)
    if len(choices) > 1:
        host = Prompt.ask("[cyan]Host[/]", choices=choices, default=LOCAL)
    node = None
    if host in clusters:
        # Whatever node the load balancer gives us: record it in the shared
        # home so we can find the session again, then start tmux there.
        script = (f'hostname >> "{NODES_FILE}"; '
                  f'sort -u -o "{NODES_FILE}" "{NODES_FILE}"; '
                  + PATH_PREFIX
                  + f"tmux new-session -d -s {shlex.quote(name)} && hostname")
        result = subprocess.run(["ssh"] + SSH_OPTS + [host, script],
                                capture_output=True, text=True)
        out = result.stdout.strip().splitlines()
        node = out[-1] if out else None
    else:
        result = subprocess.run(
            tmux_cmd(host, ["new-session", "-d", "-s", name]),
            capture_output=True, text=True,
        )
    if result.returncode != 0:
        console.print(f"[red]Error:[/] {result.stderr.strip()}")
        return
    where = f"{host}/{node}" if node else host
    console.print(f"[green]Created session '{name}' on {where}[/]")
    if Confirm.ask("Attach now?", default=True):
        attach_session({"host": host, "name": name, "node": node})


def kill_session(sessions):
    choice = Prompt.ask("[red]Session # or name to kill[/]")
    session = resolve_session(choice, sessions)
    if not session:
        console.print("[red]Invalid selection.[/]")
        return
    host_label = session["host"] + (f"/{session['node']}" if session.get("node") else "")
    label = f"{host_label}:{session['name']}"
    if not Confirm.ask(f"Kill session [bold]{label}[/bold]?", default=False):
        return
    result = subprocess.run(
        tmux_cmd(session["host"], ["kill-session", "-t", session["name"]],
                 node=session.get("node")),
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        console.print(f"[red]Error:[/] {result.stderr.strip()}")
    else:
        console.print(f"[green]Killed session '{label}'[/]")


def resolve_session(choice, sessions):
    """Resolve a choice (number, name, or host:name) to a session dict."""
    try:
        idx = int(choice) - 1
        if 0 <= idx < len(sessions):
            return sessions[idx]
    except ValueError:
        pass
    def labels(s):
        yield s["name"]
        yield f"{s['host']}:{s['name']}"
        if s.get("node"):
            yield f"{s['host']}/{s['node']}:{s['name']}"

    matches = [s for s in sessions if choice in labels(s)]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        console.print("[yellow]Ambiguous name; use host:name or the # column.[/]")
    return None


RAW_URL = "https://raw.githubusercontent.com/MoarNachos/tm/main/tm"


def self_update():
    """Replace this script with the latest version from GitHub."""
    import urllib.request

    dest = os.path.realpath(__file__)
    console.print(f"[dim]Checking {RAW_URL}[/dim]")
    try:
        with urllib.request.urlopen(RAW_URL, timeout=15) as resp:
            latest = resp.read()
    except Exception as e:
        console.print(f"[red]Update failed:[/] {e}")
        sys.exit(1)
    if not latest.startswith(b"#!"):
        console.print("[red]Update failed:[/] downloaded file doesn't look like a script")
        sys.exit(1)
    with open(dest, "rb") as f:
        if f.read() == latest:
            console.print("[green]Already up to date.[/]")
            return
    tmp = dest + ".new"
    try:
        with open(tmp, "wb") as f:
            f.write(latest)
        os.chmod(tmp, 0o755)
        os.replace(tmp, dest)
    except OSError as e:
        console.print(f"[red]Update failed:[/] {e}")
        sys.exit(1)
    console.print(f"[green]Updated {dest} to the latest version.[/]")


USAGE = """\
[bold]tm[/bold] - tmux session manager

[bold]Usage:[/] tm \\[command]

[bold]Commands:[/]
  [cyan](none)[/]          interactive UI, local + all remote hosts
  [cyan]local[/]           interactive UI, local sessions only
  [cyan]remote[/]          interactive UI, remote sessions only
  [cyan]ls[/]              list all sessions and exit
  [cyan]attach <name>[/]   attach directly (name or host:name)
  [cyan]update[/]          update tm to the latest version
  [cyan]help[/]            show this help

Remote hosts are discovered from Host entries in ~/.ssh/config.

[bold]Clusters:[/] for load-balanced hosts (ssh lands on a random node but
home dirs are shared), list the ssh alias in ~/.config/tm/clusters, one
per line. tm records the node's hostname in ~/.tm-nodes on the cluster
when creating a session, finds sessions on all recorded nodes, attaches
by hopping through the login node, and prunes nodes with no sessions."""


def main():
    args = sys.argv[1:]
    cmd = args[0] if args else ""

    if cmd in ("help", "-h", "--help"):
        console.print(USAGE)
        return
    if cmd == "update":
        self_update()
        return

    include_local = True
    clusters = cluster_hosts()
    hosts = [h for h in ssh_config_hosts() if h not in clusters]

    if cmd == "local":
        hosts = []
        clusters = []
    elif cmd == "remote":
        include_local = False
        if not hosts and not clusters:
            console.print("[yellow]No remote hosts found in ~/.ssh/config.[/]")
            sys.exit(1)
    elif cmd == "ls":
        sessions, errors = get_all_sessions(hosts, clusters)
        for host, error in errors:
            console.print(f"[yellow]{host}:[/] [dim]{error}[/dim]")
        if sessions:
            display_sessions(sessions)
        else:
            console.print("[dim]No active tmux sessions.[/dim]")
        return
    elif cmd in ("attach", "a") and len(args) > 1:
        sessions, _ = get_all_sessions(hosts, clusters)
        session = resolve_session(args[1], sessions)
        if not session:
            console.print(f"[red]No session matching '{args[1]}'.[/]")
            sys.exit(1)
        attach_session(session)
        return
    elif cmd:
        console.print(f"[red]Unknown command:[/] {cmd}\n")
        console.print(USAGE)
        sys.exit(1)

    console.print(Panel("[bold]tm[/bold] - tmux session manager", border_style="blue", expand=False))
    if include_local and not hosts and not clusters and cmd == "local":
        console.print("[dim]Local sessions only.[/dim]")
    elif hosts or clusters:
        labels = hosts + [f"{c} (cluster)" for c in clusters]
        console.print(f"[dim]Remote hosts: {', '.join(labels)}[/dim]")

    while True:
        with console.status("[dim]Scanning sessions...[/dim]"):
            sessions, errors = get_all_sessions(hosts, clusters, include_local)

        for host, error in errors:
            console.print(f"[yellow]{host}:[/] [dim]{error}[/dim]")

        if sessions:
            console.print()
            display_sessions(sessions)
        else:
            console.print("\n[dim]No active tmux sessions.[/dim]")

        console.print()
        console.print("[bold]a[/bold]=attach  [bold]n[/bold]=new  [bold]k[/bold]=kill  [bold]r[/bold]=refresh  [bold]q[/bold]=quit")
        action = Prompt.ask("[bold]>[/]", choices=["a", "n", "k", "r", "q"], default="a", show_choices=False)

        if action == "q":
            break
        elif action == "r":
            continue
        elif action == "n":
            create_session(hosts, clusters)
        elif action == "a":
            if not sessions:
                console.print("[yellow]No sessions to attach to. Create one first.[/]")
                continue
            choice = Prompt.ask("[cyan]Session # or name[/]")
            session = resolve_session(choice, sessions)
            if session:
                attach_session(session)
            else:
                console.print("[red]Invalid selection.[/]")
        elif action == "k":
            if not sessions:
                console.print("[yellow]No sessions to kill.[/]")
                continue
            kill_session(sessions)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        console.print("\n[dim]Bye.[/dim]")
