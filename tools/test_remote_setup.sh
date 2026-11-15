#!/bin/sh
# remote-setup.sh against a stub ssh: the probe's answer picks the shell, a Windows host's ssh session
# names its MSYS2 bash in DOJO_MSYS2_BASH (else C:\msys64's), and the files go in over the same ssh.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/ssh" <<'STUB'
#!/bin/sh
# The probe answers STUB_PROBE; the setup call's remote command is kept, and the tar it reads listed.
last=""
for a in "$@"; do last=$a; done
case $last in
    *"echo %OS% %DOJO_MSYS2_BASH%"*) printf '%s\r\n' "$STUB_PROBE"; exit 0 ;;
esac
printf '%s' "$last" > "$STUB_OUT/remote"
tar -tf - > "$STUB_OUT/files"
STUB
chmod +x "$tmp/bin/ssh"
run() { STUB_OUT=$tmp STUB_PROBE=$1 PATH="$tmp/bin:$PATH" sh "$here/remote-setup.sh" user@box 2>"$tmp/log"; }
fail() { echo "$1"; cat "$tmp/log"; [ -f "$tmp/remote" ] && cat "$tmp/remote"; exit 1; }
# the POSIX line inside a Windows command: base64 between "echo " and " ^|"
inner() { sed 's/.*\$^(echo \([A-Za-z0-9+/=]*\) ^|.*/\1/' "$tmp/remote" | base64 -d; }

# A POSIX host echoes the words as written.
run '%OS% %DOJO_MSYS2_BASH%'
case $(cat "$tmp/remote") in "mkdir -p ~/.dojo && tar -C ~/.dojo -xf - && python3 ~/.dojo/dojo-mcp.py install") ;; *) fail "posix line" ;; esac
[ "$(sort "$tmp/files" | tr '\n' ' ')" = "dojo-mcp.py dojo-pi.ts runner-start.sh " ] || fail "the three files go over"

# A Windows host whose session names no bash: C:\msys64's.
run 'Windows_NT %DOJO_MSYS2_BASH%'
case $(cat "$tmp/remote") in 'set MSYS2_PATH_TYPE=inherit&& C:\msys64\usr\bin\bash.exe -lc "eval \"$^(echo '*' ^| base64 -d^)\""') ;; *) fail "default bash" ;; esac
inner | grep -q 'for c in python python3; do if "$c" -c "import sys"' || fail "the first python that runs is used"
inner | grep -q 'dojo-mcp.py install' || fail "dojo install runs"

# A portable MSYS2 named by the session (sshd's SetEnv): that bash, quoted when its path has a space.
run 'Windows_NT C:\localai\Origin\tools\msys64\usr\bin\bash.exe'
case $(cat "$tmp/remote") in 'set MSYS2_PATH_TYPE=inherit&& C:\localai\Origin\tools\msys64\usr\bin\bash.exe -lc "eval '*) ;; *) fail "named bash" ;; esac
run 'Windows_NT C:\local ai\msys64\usr\bin\bash.exe'
case $(cat "$tmp/remote") in 'set MSYS2_PATH_TYPE=inherit&& "C:\local ai\msys64\usr\bin\bash.exe" -lc "eval '*) ;; *) fail "a path with a space is quoted" ;; esac

# A path with a character cmd.exe acts on is refused, named, and nothing is sent.
rm -f "$tmp/remote"
if run 'Windows_NT C:\a&b\bash.exe'; then fail "a path cmd.exe acts on must stop the setup"; fi
grep -q "names a path cmd.exe would act on" "$tmp/log" || fail "the refusal must say why"
[ ! -f "$tmp/remote" ] || fail "nothing may be sent after a refusal"
echo "remote-setup ok"
