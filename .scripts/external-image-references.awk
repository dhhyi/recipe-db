{
  if (!match($0, /"image"[[:space:]]*:[[:space:]]*"[^"]+"/)) next
  match_start = RSTART
  match_length = RLENGTH
  image = substr($0, RSTART, RLENGTH)
  sub(/^"image"[[:space:]]*:[[:space:]]*"/, "", image)
  sub(/"$/, "", image)
  suffix = substr($0, match_start + match_length)
  if (suffix !~ /^[[:space:]]*[,}]/) next
  if (image ~ /^ghcr[.]io\/dhhyi\/recipe-db-[^/@:]+:latest(@sha256:[[:xdigit:]]+)?$/) next
  print image
}
