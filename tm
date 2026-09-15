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


def tmux_cmd(host, args):
    """Build a tmux command for local or a remote host."""
    if host == LOCAL:
        return ["tmux"] + args
    # Quote for the remote shell so tmux format strings (#{...}) survive.
    # Non-interactive ssh often has a minimal PATH, so add common tmux locations.
    remote = " ".join(shlex.quote(a) for a in ["tmux"] + args)
    remote = 'PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin" ' + remote
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
        if "no server running" in err or "no sessions" in err.lower():
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


def get_all_sessions(hosts):
    """Fetch sessions from local + all hosts in parallel. Returns (sessions, errors)."""
    targets = [LOCAL] + hosts
    with ThreadPoolExecutor(max_workers=min(len(targets), 16)) as pool:
        results = pool.map(get_sessions, targets)
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
        table.add_row(
            str(i), s["host"], s["name"], s["windows"],
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
        remote = ('PATH="$PATH:/usr/local/bin:/opt/homebrew/bin:$HOME/.local/bin" '
                  f"tmux attach-session -t {shlex.quote(name)}")
        subprocess.run(["ssh", "-t"] + SSH_OPTS + [host, remote])


def create_session(hosts):
    name = Prompt.ask("[cyan]Session name[/]")
    if not name.strip():
        console.print("[red]No name given, cancelled.[/]")
        return
    host = LOCAL
    if hosts:
        host = Prompt.ask("[cyan]Host[/]", choices=[LOCAL] + hosts, default=LOCAL)
    result = subprocess.run(
        tmux_cmd(host, ["new-session", "-d", "-s", name]),
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        console.print(f"[red]Error:[/] {result.stderr.strip()}")
        return
    console.print(f"[green]Created session '{name}' on {host}[/]")
    if Confirm.ask("Attach now?", default=True):
        attach_session({"host": host, "name": name})


def kill_session(sessions):
    choice = Prompt.ask("[red]Session # or name to kill[/]")
    session = resolve_session(choice, sessions)
    if not session:
        console.print("[red]Invalid selection.[/]")
        return
    label = f"{session['host']}:{session['name']}"
    if not Confirm.ask(f"Kill session [bold]{label}[/bold]?", default=False):
        return
    result = subprocess.run(
        tmux_cmd(session["host"], ["kill-session", "-t", session["name"]]),
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
    matches = [s for s in sessions
               if s["name"] == choice or f"{s['host']}:{s['name']}" == choice]
    if len(matches) == 1:
        return matches[0]
    if len(matches) > 1:
        console.print("[yellow]Ambiguous name; use host:name or the # column.[/]")
    return None


def main():
    console.print(Panel("[bold]tm[/bold] - tmux session manager", border_style="blue", expand=False))
    hosts = ssh_config_hosts()
    if hosts:
        console.print(f"[dim]Remote hosts: {', '.join(hosts)}[/dim]")

    while True:
        with console.status("[dim]Scanning sessions...[/dim]"):
            sessions, errors = get_all_sessions(hosts)

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
            create_session(hosts)
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
