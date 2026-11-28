let fail = Alcotest.fail

let check condition message = Alcotest.(check bool) message true condition

let expect_database_error action =
  try
    ignore (action ());
    fail "Expected database error"
  with Tags.Database_error _ -> ()

let with_database action =
  let path = Filename.temp_file "tags-test" ".sqlite" in
  let cleanup () =
    List.iter
      (fun suffix ->
        if Sys.file_exists (path ^ suffix) then Sys.remove (path ^ suffix))
      [ ""; "-wal"; "-shm" ]
  in
  let database = Tags.open_database (Some path) in
  Fun.protect
    ~finally:(fun () ->
      Tags.close_database database;
      cleanup ())
    (fun () -> action database)

let test_assignment_atomic_rollback () =
  with_database (fun database ->
      let first = Tags.create_tag database Tags.Course "Starter" in
      let second = Tags.create_tag database Tags.Course "Main" in
      Tags.assign_one database "opaque/recipe id" first.id;
      ignore
        (Sqlite3.exec database
           "CREATE TRIGGER reject_second BEFORE INSERT ON assignments \
            WHEN NEW.tag_id = 'course-starter' BEGIN \
            SELECT RAISE(ABORT, 'forced failure'); END");
      expect_database_error (fun () ->
          Tags.bulk_change database "opaque/recipe id" [ first.id; second.id ] []);
      check
        (Tags.assigned_tags database "opaque/recipe id"
         |> List.map (fun (tag : Tags.tag) -> tag.id) = [ first.id ])
        "failed bulk changes must roll back earlier writes")

let test_restart_persistence () =
  let path = Filename.temp_file "tags" ".sqlite" in
  Fun.protect
    ~finally:(fun () ->
      List.iter
        (fun suffix -> if Sys.file_exists (path ^ suffix) then Sys.remove (path ^ suffix))
        [ ""; "-wal"; "-shm" ])
    (fun () ->
      let first = Tags.open_database (Some path) in
      let tag = Tags.create_tag first Tags.Cuisine "Thai" in
      Tags.assign_one first "recipe" tag.id;
      Tags.close_database first;
      let restarted = Tags.open_database (Some path) in
      Fun.protect
        ~finally:(fun () -> Tags.close_database restarted)
        (fun () ->
          check
            (Tags.select_tags restarted ()
            |> List.map (fun (tag : Tags.tag) -> tag.id) = [ "cuisine-thai" ])
            "inventory must persist after restart";
          check
            (Tags.assigned_tags restarted "recipe"
            |> List.map (fun (tag : Tags.tag) -> tag.id)
               = [ "cuisine-thai" ])
            "assignments must persist after restart";
          Tags.reset_database restarted);
      let empty = Tags.open_database (Some path) in
      Fun.protect
        ~finally:(fun () -> Tags.close_database empty)
        (fun () ->
          check (Tags.select_tags empty () = [])
            "empty reset result must persist after restart"))

let test_reset_is_complete_and_transactional () =
  with_database (fun database ->
      let tag = Tags.create_tag database Tags.Course "Assigned" in
      Tags.assign_one database "recipe" tag.id;
      ignore
        (Sqlite3.exec database
           "CREATE TRIGGER reject_tag_delete BEFORE DELETE ON tags \
            BEGIN SELECT RAISE(ABORT, 'forced failure'); END");
      expect_database_error (fun () -> Tags.reset_database database);
      check (List.length (Tags.select_tags database ()) = 1)
        "reset errors must roll back inventory deletion";
      check (List.length (Tags.assigned_tags database "recipe") = 1)
        "reset errors must roll back assignment deletion";
      ignore (Sqlite3.exec database "DROP TRIGGER reject_tag_delete");
      ignore (Sqlite3.exec database "PRAGMA foreign_keys = OFF");
      ignore
        (Sqlite3.exec database
           "INSERT INTO assignments(recipe_id, tag_id) VALUES ('orphan', 'missing')");
      ignore (Sqlite3.exec database "PRAGMA foreign_keys = ON");
      Tags.reset_database database;
      Tags.reset_database database;
      check (Tags.select_tags database () = []) "reset clears the full inventory";
      check
        (Tags.assigned_tags database "orphan" = [])
        "reset clears even orphaned assignments")

let test_backup_rejects_missing_tables () =
  let valid_path = Filename.temp_file "tags-backup-valid" ".sqlite" in
  let valid_db = Tags.open_database (Some valid_path) in
  Tags.close_database valid_db;
  let backup_db = Tags.open_database ~mode:Tags.Backup (Some valid_path) in
  Tags.close_database backup_db;
  Sys.remove valid_path;
  List.iter
    (fun missing ->
      let path = Filename.temp_file "tags-backup" ".sqlite" in
      let db = Tags.open_database (Some path) in
      Tags.exec db ("DROP TABLE " ^ missing);
      Tags.close_database db;
      let original = In_channel.with_open_bin path In_channel.input_all in
      expect_database_error (fun () -> Tags.open_database ~mode:Tags.Backup (Some path));
      check (In_channel.with_open_bin path In_channel.input_all = original)
        "backup rejection leaves the database unchanged";
      Sys.remove path)
    [ "tags"; "assignments" ]

let test_backup_rejects_missing_database_paths () =
  let root = Filename.temp_file "tags-backup-startup" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let existing = Filename.concat root "existing" in
  let absent_database = Filename.concat root "absent.sqlite" in
  let orphan_database = Filename.concat root "orphan.sqlite" in
  let orphan_wal = orphan_database ^ "-wal" in
  let missing_parent = Filename.concat root "missing" in
  let database_in_missing_parent = Filename.concat missing_parent "tags.sqlite" in
  let write_file path contents =
    Out_channel.with_open_bin path (fun channel -> output_string channel contents)
  in
  let read_file path = In_channel.with_open_bin path In_channel.input_all in
  let remove_if_exists path = if Sys.file_exists path then Sys.remove path in
  Fun.protect
    ~finally:(fun () ->
      List.iter remove_if_exists
        [
          existing;
          absent_database;
          orphan_database;
          orphan_wal;
          orphan_database ^ "-shm";
          database_in_missing_parent;
          database_in_missing_parent ^ "-wal";
          database_in_missing_parent ^ "-shm";
        ];
      if Sys.file_exists missing_parent then Unix.rmdir missing_parent;
      Unix.rmdir root)
    (fun () ->
      write_file existing "preserve this file";
      expect_database_error (fun () ->
          Tags.open_database ~mode:Tags.Backup (Some absent_database));
      check (not (Sys.file_exists absent_database))
        "backup rejection must not create an absent database";
      check (not (Sys.file_exists (absent_database ^ "-wal")))
        "backup rejection must not create a WAL beside an absent database";
      check (not (Sys.file_exists (absent_database ^ "-shm")))
        "backup rejection must not create shared memory beside an absent database";
      check (read_file existing = "preserve this file")
        "backup rejection must preserve existing files";
      write_file orphan_wal "orphaned WAL data";
      expect_database_error (fun () ->
          Tags.open_database ~mode:Tags.Backup (Some orphan_database));
      check (not (Sys.file_exists orphan_database))
        "backup rejection must not create a database beside an orphaned WAL";
      check (not (Sys.file_exists (orphan_database ^ "-shm")))
        "backup rejection must not create shared memory beside an orphaned WAL";
      check (read_file orphan_wal = "orphaned WAL data")
        "backup rejection must preserve an orphaned WAL";
      check (read_file existing = "preserve this file")
        "backup rejection must preserve unrelated existing files";
      expect_database_error (fun () ->
          Tags.open_database ~mode:Tags.Backup (Some database_in_missing_parent));
      check (not (Sys.file_exists missing_parent))
        "backup rejection must not create a missing parent directory";
      check (not (Sys.file_exists database_in_missing_parent))
        "backup rejection must not create a database in a missing parent";
      check (not (Sys.file_exists (database_in_missing_parent ^ "-wal")))
        "backup rejection must not create a WAL in a missing parent";
      check (not (Sys.file_exists (database_in_missing_parent ^ "-shm")))
        "backup rejection must not create shared memory in a missing parent";
      check (read_file existing = "preserve this file")
        "backup rejection must preserve existing files")

let request ?(mode = Tags.Testing) ?(method_ = `GET) ?(body = "") db target =
  Dream.test (Tags.router ~mode db)
    (Dream.request ~method_ ~target
       ~headers:[ ("Content-Type", "application/json") ] body)

let assert_status status response =
  check (Dream.status response = Dream.int_to_status status)
    (Printf.sprintf "Expected HTTP %d, received %d" status
       (Dream.status response |> Dream.status_to_int))

let assert_problem status code response =
  assert_status status response;
  check (Dream.header response "Content-Type" = Some "application/problem+json")
    "Problem Details content type";
  let json = Lwt_main.run (Dream.body response) |> Yojson.Basic.from_string in
  let open Yojson.Basic.Util in
  check (json |> member "type" |> to_string = "about:blank") "problem type";
  check (json |> member "status" |> to_int = status) "problem status";
  check (json |> member "code" |> to_string = code) "problem code"

let test_runtime_modes_and_http_reset () =
  check (Tags.mode_of_environment None = Tags.Production) "unset mode is production";
  check (Tags.mode_of_environment (Some "production") = Tags.Production)
    "explicit production mode";
  check (Tags.mode_of_environment (Some "testing") = Tags.Testing) "testing mode";
  check (Tags.mode_of_environment (Some "backup") = Tags.Backup) "backup mode";
  List.iter
    (fun mode ->
      match Tags.mode_of_environment (Some mode) with
      | _ -> fail "Invalid mode was accepted"
      | exception Invalid_argument _ -> ())
    [ ""; "unknown"; "Testing" ];
  with_database (fun db ->
      let tag = Tags.create_tag db Tags.Course "Protected" in
      Tags.assign_one db "recipe" tag.id;
      Tags.assign_one db "opaque/recipe id" tag.id;
      List.iter
        (fun mode ->
          assert_status 204 (request ~mode db "/health");
          List.iter
            (fun path ->
              assert_problem 404 "not-found" (request ~mode db path))
            [ "/maintenance/status"; "/maintenance/recipe-ids" ];
          List.iter
            (fun target ->
              assert_problem 404 "not-found" (request ~mode ~method_:`DELETE db target);
              check (List.length (Tags.select_tags db ()) = 1) "denied reset retains tags";
              check (List.length (Tags.assigned_tags db "recipe") = 1)
                "denied reset retains assignments")
            [ "/tags"; "/tags/" ])
        [ Tags.mode_of_environment None; Tags.Production ];
      let backup_status = request ~mode:Tags.Backup db "/maintenance/status" in
      assert_status 200 backup_status;
      let backup_status_json =
        Lwt_main.run (Dream.body backup_status) |> Yojson.Basic.from_string
      in
      let open Yojson.Basic.Util in
      check (backup_status_json |> member "version" |> to_int = 1)
        "backup API version";
      check (backup_status_json |> member "service" |> to_string = "tags")
        "backup API service";
      check (backup_status_json |> member "mode" |> to_string = "backup")
        "backup API mode";
      let ids = request ~mode:Tags.Backup db "/maintenance/recipe-ids/" in
      assert_status 200 ids;
      let ids_json = Lwt_main.run (Dream.body ids) |> Yojson.Basic.from_string in
      check
        (ids_json |> member "recipeIds" |> to_list |> List.map to_string
        = [ "opaque/recipe id"; "recipe" ])
        "recipe IDs are complete, distinct, and ordered";
      let purge =
        request ~mode:Tags.Backup ~method_:`POST
          ~body:{|{"recipeId":"opaque/recipe id"}|} db
          "/maintenance/recipes/purge"
      in
      assert_status 204 purge;
      assert_status 204
        (request ~mode:Tags.Backup ~method_:`POST
           ~body:{|{"recipeId":"opaque/recipe id"}|} db
           "/maintenance/recipes/purge");
      check (Tags.assigned_tags db "opaque/recipe id" = [])
        "purge deletes assignments for the exact opaque ID";
      check (List.length (Tags.assigned_tags db "recipe") = 1)
        "purge preserves unrelated assignments";
      check (Tags.tag_exists db tag.id) "purge preserves shared inventory";
      assert_problem 503 "maintenance-mode"
        (request ~mode:Tags.Backup ~method_:`DELETE db "/tags");
      List.iter
        (fun target ->
          assert_status 204 (request ~method_:`DELETE db target);
          check (Tags.select_tags db () = []) "HTTP reset clears inventory";
          check (Tags.assigned_tags db "recipe" = []) "HTTP reset clears assignments")
        [ "/tags/"; "/tags"; "/tags/" ])

let test_http_errors_and_rollback () =
  with_database (fun db ->
      let tag = Tags.create_tag db Tags.Course "Retained" in
      Tags.assign_one db "recipe" tag.id;
      Tags.exec db
        "CREATE TRIGGER reject_reset BEFORE DELETE ON tags \
         BEGIN SELECT RAISE(ABORT, 'forced failure'); END";
      assert_problem 500 "database-error" (request ~method_:`DELETE db "/tags");
      check (List.length (Tags.select_tags db ()) = 1) "failed HTTP reset retains tags";
      check (List.length (Tags.assigned_tags db "recipe") = 1)
        "failed HTTP reset retains assignments";
      Tags.exec db "DROP TRIGGER reject_reset";
      let second = Tags.create_tag db Tags.Course "Second" in
      Tags.exec db
        "CREATE TRIGGER reject_assignment BEFORE INSERT ON assignments \
         BEGIN SELECT RAISE(ABORT, 'forced failure'); END";
      assert_problem 500 "database-error"
        (request ~method_:`PATCH
           ~body:(Printf.sprintf {|{"addTagIds":["%s"],"removeTagIds":["%s"]}|} second.id tag.id)
           db "/tags/recipes/recipe");
      check (List.map (fun (t : Tags.tag) -> t.id) (Tags.assigned_tags db "recipe") = [ tag.id ])
        "failed HTTP bulk change retains assignments")

let () =
  Alcotest.run "Tags"
    [
      ( "storage",
        [
          Alcotest.test_case "assignment rollback" `Quick test_assignment_atomic_rollback;
          Alcotest.test_case "restart persistence" `Quick test_restart_persistence;
          Alcotest.test_case "transactional reset" `Quick test_reset_is_complete_and_transactional;
          Alcotest.test_case "backup rejects missing tables" `Quick test_backup_rejects_missing_tables;
          Alcotest.test_case "backup rejects missing paths" `Quick test_backup_rejects_missing_database_paths;
        ] );
      ( "http",
        [
          Alcotest.test_case "runtime modes and reset" `Quick test_runtime_modes_and_http_reset;
          Alcotest.test_case "errors and rollback" `Quick test_http_errors_and_rollback;
        ] );
    ]
