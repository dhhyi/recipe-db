#!/bin/sh
awk '
$1 == "storageVersion:" {
  if (NF != 2 || $2 !~ /^[1-9][0-9]*$/) exit 1
  count++
  version = $2
}
END {
  if (count != 1) exit 1
  print "let value = " version
}
' "$1"
