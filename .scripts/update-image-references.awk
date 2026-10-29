BEGIN {
  while ((getline entry < replacements_file) > 0) {
    split(entry, fields, "\t")
    replacements[fields[1]] = fields[2]
  }
  close(replacements_file)
}

mode == "template" {
  if (match($0, /"image"[[:space:]]*:[[:space:]]*"[^"]+"/)) {
    match_start = RSTART
    match_length = RLENGTH
    matched_text = substr($0, RSTART, RLENGTH)
    image = matched_text
    sub(/^"image"[[:space:]]*:[[:space:]]*"/, "", image)
    sub(/"$/, "", image)
    if (image in replacements) {
      prefix = substr(matched_text, 1, length(matched_text) - length(image) - 1)
      print substr($0, 1, match_start - 1) prefix replacements[image] substr($0, match_start + match_length - 1)
      next
    }
  }
  print
  next
}

mode == "deployment" {
  if ($0 ~ /^infrastructure:[[:space:]]*($|#)/) {
    in_infrastructure = 1
    print
    next
  }
  if ($0 !~ /^[[:space:]]/ && $0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*#/) {
    in_infrastructure = 0
  }
  if (in_infrastructure && match($0, /^[[:space:]]*[^:]+:[[:space:]]*/)) {
    prefix = substr($0, 1, RLENGTH)
    value = substr($0, RLENGTH + 1)
    if (match(value, /^"[^"]+"/)) {
      image = substr(value, 2, RLENGTH - 2)
      prefix = prefix substr(value, 1, 1)
      suffix = substr(value, RLENGTH)
    } else if (match(value, /^'[^']+'/)) {
      image = substr(value, 2, RLENGTH - 2)
      prefix = prefix substr(value, 1, 1)
      suffix = substr(value, RLENGTH)
    } else if (match(value, /^[^[:space:]#]+/)) {
      image = substr(value, 1, RLENGTH)
      suffix = substr(value, RLENGTH + 1)
    } else {
      print
      next
    }
    if (image in replacements) {
      print prefix replacements[image] suffix
      next
    }
  }
  print
}
