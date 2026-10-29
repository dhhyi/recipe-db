let fail message = raise (Failure message)

let check condition message = if not condition then fail message

let expect_problem code action =
  try
    ignore (action ());
    fail ("Expected problem: " ^ code)
  with
  | Tags.Problem problem when problem.code = code -> ()

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

let test_identity_and_validation () =
  check
    (Tags.identity_key "  Crème brûlée  " = "cremebrulee")
    "accent folding and Unicode whitespace";
  check
    (Tags.identity_key "Straße" = "strasse")
    "full Unicode case folding";
  check
    (Tags.display_name "  Crème brûlée  " = "Crème brûlée")
    "NFC display normalization";
  check (Tags.display_name "\194\160Soup\194\160" = "Soup")
    "Unicode whitespace trimming";
  List.iter
    (fun value ->
      expect_problem "invalid-tag-name" (fun () ->
          Tags.identity_key value))
    [ "!!!"; "́"; "ø"; "漢"; "caféø"; "a\nb" ];
  expect_problem "invalid-tag-name" (fun () ->
      Tags.display_name (String.make 101 'a'))

let test_creation_and_collisions () =
  with_database (fun database ->
      let tag = Tags.create_tag database Tags.Dietary_style "Gluten-free" in
      check (tag.id = "dietary-style-glutenfree") "stable tag ID";
      check (tag.name = "Gluten-free") "first spelling retained";
      expect_problem "tag-collision" (fun () ->
          Tags.create_tag database Tags.Dietary_style "gluten free");
      check
         ((Tags.select_tags database ())
         |> List.map (fun (tag : Tags.tag) -> tag.name)
        = [ "Gluten-free" ])
        "collision must not create or rename an inventory entry";
      let other_category = Tags.create_tag database Tags.Course "Gluten-free" in
      check (other_category.id = "course-glutenfree")
        "same key is allowed in another category")

let test_deterministic_ordering () =
  with_database (fun database ->
      ignore (Tags.create_tag database Tags.Course "A-y");
      ignore (Tags.create_tag database Tags.Course "A!z");
      ignore (Tags.create_tag database Tags.Cuisine "Soup");
      ignore (Tags.create_tag database Tags.Dietary_style "vegan");
      check
        (Tags.select_tags database ()
         |> List.map (fun (tag : Tags.tag) -> tag.name)
        = [ "Soup"; "vegan"; "A!z"; "A-y" ])
        "category order and display-name ordering")

let test_assignments_and_atomic_rollback () =
  with_database (fun database ->
      let first = Tags.create_tag database Tags.Course "Starter" in
      let second = Tags.create_tag database Tags.Course "Main" in
      Tags.assign_one database "opaque/recipe id" first.id;
      Tags.assign_one database "opaque/recipe id" first.id;
      check
        (Tags.assigned_tags database "opaque/recipe id"
         |> List.map (fun (tag : Tags.tag) -> tag.id) = [ first.id ])
        "single assignment is idempotent";
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
        "failed bulk changes must roll back earlier writes";
      expect_problem "tag-in-use" (fun () -> Tags.delete_tag database first.id);
      Tags.remove_one database "opaque/recipe id" first.id;
      Tags.remove_one database "opaque/recipe id" first.id;
      Tags.delete_tag database first.id;
      check (not (Tags.tag_exists database first.id)) "unused tag is deleted")

let test_bulk_validation_and_conflicts () =
  with_database (fun database ->
      let tag = Tags.create_tag database Tags.Cuisine "Italian" in
      expect_problem "unknown-tag" (fun () ->
          Tags.bulk_change database "recipe" [ "cuisine-missing" ] []);
      expect_problem "conflicting-tag-change" (fun () ->
          Tags.bulk_change database "recipe" [ tag.id ] [ tag.id ]);
      check (Tags.assigned_tags database "recipe" = [])
        "invalid bulk changes leave assignments unchanged";
      let result =
        Tags.bulk_change database "recipe" [ tag.id; tag.id ] []
      in
       check (List.map (fun (value : Tags.tag) -> value.id) result = [ tag.id ])
        "bulk add deduplicates IDs")

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
  List.iter
    (fun mode ->
      match Tags.mode_of_environment (Some mode) with
      | _ -> fail "Invalid mode was accepted"
      | exception Invalid_argument _ -> ())
    [ ""; "unknown"; "backup"; "Testing" ];
  with_database (fun db ->
      let tag = Tags.create_tag db Tags.Course "Protected" in
      Tags.assign_one db "recipe" tag.id;
      List.iter
        (fun mode ->
          assert_status 204 (request ~mode db "/health");
          List.iter
            (fun target ->
              assert_problem 404 "not-found" (request ~mode ~method_:`DELETE db target);
              check (List.length (Tags.select_tags db ()) = 1) "denied reset retains tags";
              check (List.length (Tags.assigned_tags db "recipe") = 1)
                "denied reset retains assignments")
            [ "/tags"; "/tags/" ])
        [ Tags.mode_of_environment None; Tags.Production ];
      List.iter
        (fun target ->
          assert_status 204 (request ~method_:`DELETE db target);
          check (Tags.select_tags db () = []) "HTTP reset clears inventory";
          check (Tags.assigned_tags db "recipe" = []) "HTTP reset clears assignments")
        [ "/tags/"; "/tags"; "/tags/" ])

let test_http_errors_and_rollback () =
  with_database (fun db ->
      List.iter
        (fun path -> assert_problem 422 "invalid-request" (request db path))
        [ "/tags/recipes/%"; "/tags/recipes/%GG"; "/tags/recipes/%+1" ];
      assert_problem 422 "invalid-request"
        (request ~method_:`POST ~body:{|{"category":"course","name":"A","name":"B"}|} db "/tags");
      assert_problem 400 "invalid-json"
        (request ~method_:`POST ~body:"{" db "/tags");
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
  test_identity_and_validation ();
  test_creation_and_collisions ();
  test_deterministic_ordering ();
  test_assignments_and_atomic_rollback ();
  test_bulk_validation_and_conflicts ();
  test_restart_persistence ();
  test_reset_is_complete_and_transactional ();
  test_runtime_modes_and_http_reset ();
  test_http_errors_and_rollback ()
