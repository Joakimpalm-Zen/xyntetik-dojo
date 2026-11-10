#!/bin/sh
# Put the shim, the pi extension and Runner's start script in ~/.dojo on an ssh host and run "dojo install" there.
# A Windows host (OpenSSH with cmd.exe) gets the same commands through MSYS2 bash, in the shape
# Launcher.windowsRemoteCommand builds for a pane: the POSIX line travels as base64 so cmd.exe never sees
# a quote, a pipe or a percent sign from it. The bash is the one the ssh session names in DOJO_MSYS2_BASH
# (sshd's SetEnv, or the user's environment), else C:\msys64's, as the app's probe reads it.
set -e
host=$1
if [ -z "$host" ]; then
    echo "usage: remote-setup.sh user@box" >&2
    exit 2
fi
tools=$(cd "$(dirname "$0")" && pwd)
probe=$(ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" 'echo %OS% %DOJO_MSYS2_BASH%' 2>/dev/null | tr -d '\r' | head -1)
case $probe in
    Windows_NT*)
        # cmd.exe leaves %DOJO_MSYS2_BASH% as written when the session does not set it
        bash_path=$(printf '%s' "${probe#Windows_NT}" | sed 's/^ *//; s/ *$//')
        case $bash_path in ''|*%*) bash_path='C:\msys64\usr\bin\bash.exe' ;; esac
        # the app's rule: a path with a character cmd.exe acts on is not used
        if printf '%s' "$bash_path" | LC_ALL=C grep -q '[^A-Za-z0-9 :\\/._()-]'; then
            echo "DOJO_MSYS2_BASH on $host names a path cmd.exe would act on: $bash_path" >&2
            exit 2
        fi
        case $bash_path in *" "*) bash_cmd="\"$bash_path\"" ;; *) bash_cmd=$bash_path ;; esac
        # The first of python and python3 that runs: with MSYS2_PATH_TYPE=inherit the Windows PATH comes
        # first, and either name can be the Microsoft Store stub, which is found but does not run.
        # dojo install then writes ~/.dojo/bin/python3 for that same Python, which the panes put first.
        inner='mkdir -p ~/.dojo && tar -C ~/.dojo -xf - && py= && for c in python python3; do if "$c" -c "import sys" >/dev/null 2>&1; then py=$c; break; fi; done && if [ -z "$py" ]; then echo "no python that runs on this host (only the Store stub?)" >&2; exit 3; fi && "$py" ~/.dojo/dojo-mcp.py install'
        encoded=$(printf '%s' "$inner" | base64 | tr -d '\n')
        remote="set MSYS2_PATH_TYPE=inherit&& $bash_cmd -lc \"eval \\\"\$^(echo $encoded ^| base64 -d^)\\\"\""
        ;;
    *)
        remote='mkdir -p ~/.dojo && tar -C ~/.dojo -xf - && python3 ~/.dojo/dojo-mcp.py install'
        ;;
esac
# runner-start.sh is what a Runner pane on the host runs (D12): the same script as on this Mac.
COPYFILE_DISABLE=1 tar -C "$tools" -cf - dojo-mcp.py dojo-pi.ts runner-start.sh | ssh "$host" "$remote"
