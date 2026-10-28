#!/bin/sh
# Put the shim and the pi extension in ~/.xhs on an ssh host and run "xhs install" there.
# A Windows host (OpenSSH with cmd.exe) gets the same commands through MSYS2 bash at C:\msys64,
# in the shape Launcher.windowsRemoteCommand builds for a pane: the POSIX line travels as base64
# so cmd.exe never sees a quote, a pipe or a percent sign from it.
set -e
host=$1
if [ -z "$host" ]; then
    echo "usage: remote-setup.sh user@box" >&2
    exit 2
fi
tools=$(cd "$(dirname "$0")" && pwd)
case $(ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" 'echo %OS%' 2>/dev/null) in
    Windows_NT*)
        inner='mkdir -p ~/.xhs && tar -C ~/.xhs -xf - && python ~/.xhs/xhs-mcp.py install'
        encoded=$(printf '%s' "$inner" | base64 | tr -d '\n')
        remote="set MSYS2_PATH_TYPE=inherit&& C:\\msys64\\usr\\bin\\bash.exe -lc \"eval \\\"\$^(echo $encoded ^| base64 -d^)\\\"\""
        ;;
    *)
        remote='mkdir -p ~/.xhs && tar -C ~/.xhs -xf - && python3 ~/.xhs/xhs-mcp.py install'
        ;;
esac
COPYFILE_DISABLE=1 tar -C "$tools" -cf - xhs-mcp.py xhs-pi.ts | ssh "$host" "$remote"
