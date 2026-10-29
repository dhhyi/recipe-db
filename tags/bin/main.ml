let () =
  let mode = Option.value (Sys.getenv_opt "MODE") ~default:"production" in
  if mode <> "production" && mode <> "testing" then (
    prerr_endline "Invalid MODE; expected production or testing";
    exit 1);
  let database = Tags.open_database (Sys.getenv_opt "DATA_LOCATION") in
  let port =
    match Sys.getenv_opt "PORT" with
    | None -> 8900
    | Some value -> (try int_of_string value with Failure _ -> 8900)
  in
  Dream.run ~interface:"0.0.0.0" ~port (Dream.logger (Tags.router database))
