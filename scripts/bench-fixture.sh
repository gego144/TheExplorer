#!/bin/zsh
# Makes a folder for the `bench` scene: "Alpha" and "Beta" folders with files in them, and
# 1,000 files at the top including "file-0042.txt".
set -e
dir=${1:?usage: bench-fixture.sh <folder>}
mkdir -p "$dir/Alpha" "$dir/Beta"
for i in $(seq -f %04g 0 999); do print "file $i" > "$dir/file-$i.txt"; done
for i in $(seq -f %04g 0 499); do print "a $i" > "$dir/Alpha/a-$i.txt"; print "b $i" > "$dir/Beta/b-$i.md"; done
echo "Bench folder ready: $dir"
