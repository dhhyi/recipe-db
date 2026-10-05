function fail(message) {
  print FILENAME ": " message > "/dev/stderr"
  exit 1
}

function resolve(image, stage_pattern, token, name, value, result) {
  result = ""
  while (match(image, /\$\{[A-Za-z_][A-Za-z0-9_]*\}|\$[A-Za-z_][A-Za-z0-9_]*/)) {
    token = substr(image, RSTART, RLENGTH)
    name = token
    gsub(/[$ {}]/, "", name)
    if (name in args && args[name] != "") {
      value = args[name]
    } else if (stage_pattern) {
      value = "[^/:[:space:]]+"
    } else {
      fail("missing build argument " name " for base image")
    }
    result = result substr(image, 1, RSTART - 1) value
    image = substr(image, RSTART + RLENGTH)
  }
  return result image
}

BEGIN {
  while ((getline entry < args_file) > 0) {
    separator = index(entry, "\t")
    args[substr(entry, 1, separator - 1)] = substr(entry, separator + 1)
  }
  close(args_file)
  if (mode == "write") {
    while ((getline entry < digest_file) > 0) {
      split(entry, fields, "\t")
      digests[fields[1]] = fields[2]
    }
    close(digest_file)
  }
}

toupper($1) == "ARG" && !seen_from {
  split($2, declaration, "=")
  if (!(declaration[1] in args) && index($2, "=")) {
    args[declaration[1]] = substr($2, index($2, "=") + 1)
  }
}

toupper($1) == "FROM" {
  seen_from = 1
  image_field = 2
  while ($image_field ~ /^--/) image_field++
  original = $image_field
  image = original
  sub(/@sha256:[[:xdigit:]]+$/, "", image)
  internal = tolower(image) == "scratch" || tolower(image) in stages
  if (!internal && index(image, "$")) {
    pattern = "^" resolve(tolower(image), 1) "$"
    for (stage in stages) {
      if (stage ~ pattern) internal = 1
    }
  }
  if (!internal) {
    resolved = resolve(image, 0)
    if (mode == "scan") {
      print resolved
    } else {
      if (!(resolved in digests)) fail("missing digest for " resolved)
      match($0, /^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+(--[^[:space:]]+[[:space:]]+)*/)
      prefix = substr($0, 1, RLENGTH)
      $0 = prefix image "@" digests[resolved] substr($0, RLENGTH + length(original) + 1)
    }
  }
  if (toupper($(image_field + 1)) == "AS") stages[tolower($(image_field + 2))] = 1
}

mode == "write" { print }
