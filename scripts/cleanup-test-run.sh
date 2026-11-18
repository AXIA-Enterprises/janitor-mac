#!/bin/bash
S="$1"; T=$S/jtest; U=$(id -u)
J="$HOME/Library/Developer/Xcode/DerivedData/Janitor-build/Build/Products/Release/Janitor.app/Contents/MacOS/Janitor"
DDR=$T/home/Library/Developer/Xcode/DerivedData; SC=$T/private/tmp/claude-$U/projA/sess1/scratchpad
(exec sleep 7200) < "$DDR/OpenFile-ghi/Build/Intermediates/a.o" &
perl -e 'sleep 7200' -- "$DDR/CmdLine-jkl" &
(cd "$DDR/CwdOnly-mno" && exec sleep 7200) &
perl -e 'sleep 7200' -- "$SC/dd-10/Build" &
sleep 2
strip(){ sed "s|$T||g" | cut -c1-210; }
sum(){ find "$T" -not -path "*/Library/Logs*" | sort | shasum | cut -c1-16; }
echo "===== 1. DRY RUN  (started $(date +%T))"; B=$(sum)
"$J" --cleanup --dry-run --test-root "$T" 2>&1 | strip
echo "tree checksum before $B, after $(sum)  (finished $(date +%T))"
echo; echo "===== 2. REAL RUN"
"$J" --cleanup --test-root "$T" 2>&1 | strip
echo "(finished $(date +%T))"
echo; echo "===== 3. WHAT IS LEFT"
for d in $DDR/* $SC/* $T/private/tmp/other/* $T/home/Builds/*/* $T/home/Precious/important.txt; do echo "  still there: ${d#$T}"; done
echo; echo "===== 4. LOW-DISK MODE (pretend 20 GB free), dry run"
"$J" --cleanup --dry-run --no-sizes --test-root "$T" --assume-free-gb 20 2>&1 | strip
echo; echo "===== 5. LOG FILE"; cat "$T/home/Library/Logs/Janitor/cleanup.log" | strip
pkill -f 'sleep 7200'
echo "ALL DONE $(date +%T)"
