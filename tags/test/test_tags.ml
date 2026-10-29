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

let () =
  test_identity_and_validation ();
  test_creation_and_collisions ();
  test_deterministic_ordering ();
  test_assignments_and_atomic_rollback ();
  test_bulk_validation_and_conflicts ();
  test_restart_persistence ();
  test_reset_is_complete_and_transactional ()
