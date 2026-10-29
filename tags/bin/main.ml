let () =
  let mode =
    try Tags.mode_of_environment (Sys.getenv_opt "MODE")
    with Invalid_argument message -> prerr_endline message; exit 1
  in
  let database = Tags.open_database (Sys.getenv_opt "DATA_LOCATION") in
  let port =
    match Sys.getenv_opt "PORT" with
    | None -> 8900
    | Some value ->
        (match int_of_string_opt value with
        | Some port when port > 0 && port <= 65535 -> port
        | _ -> prerr_endline "Invalid PORT; expected an integer from 1 to 65535"; exit 1)
  in
  Dream.run ~interface:"0.0.0.0" ~port (Dream.logger (Tags.router ~mode database))
