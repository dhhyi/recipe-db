open Lwt.Infix

type category = Cuisine | Dietary_style | Course

type tag = { id : string; category : category; name : string }

type problem = {
  status : int;
  title : string;
  detail : string;
  code : string;
  field : string option;
}

exception Problem of problem
exception Database_error of string

type mode = Production | Testing

let mode_of_environment = function
  | None | Some "production" -> Production
  | Some "testing" -> Testing
  | Some _ -> invalid_arg "Invalid MODE; expected production or testing"

let category_slug = function
  | Cuisine -> "cuisine"
  | Dietary_style -> "dietary-style"
  | Course -> "course"

let category_of_string = function
  | "cuisine" -> Some Cuisine
  | "dietary-style" -> Some Dietary_style
  | "course" -> Some Course
  | _ -> None

let category_order = function Cuisine -> 0 | Dietary_style -> 1 | Course -> 2

let problem ?field status title detail code =
  { status; title; detail; code; field }

let invalid_request ?field detail =
  raise (Problem (problem ?field 422 "Invalid request" detail "invalid-request"))

let invalid_ids ?field detail =
  raise (Problem (problem ?field 422 "Invalid tag IDs" detail "invalid-tag-ids"))

let invalid_name detail =
  raise
    (Problem
       (problem ~field:"name" 422 "Invalid tag name" detail "invalid-tag-name"))

let rec decode_utf8 text index accumulated =
  if index >= String.length text then Some (List.rev accumulated)
  else
    let decoded = String.get_utf_8_uchar text index in
    if not (Uchar.utf_decode_is_valid decoded) then None
    else
      decode_utf8 text
        (index + Uchar.utf_decode_length decoded)
        (Uchar.utf_decode_uchar decoded :: accumulated)

let encode_uchar buffer value = Buffer.add_utf_8_uchar buffer value

let encode_uchars values =
  let buffer = Buffer.create 32 in
  List.iter (encode_uchar buffer) values;
  Buffer.contents buffer

let validate_utf8 text =
  match decode_utf8 text 0 [] with
  | Some values -> values
  | None -> invalid_name "The name must contain valid Unicode text."

let display_name input =
  let points = validate_utf8 input in
  let rec drop_leading = function
    | value :: rest when Uucp.White.is_white_space value -> drop_leading rest
    | rest -> rest
  in
  let rec drop_trailing = function
    | [] -> []
    | values ->
        let reversed = List.rev values in
        drop_leading reversed |> List.rev
  in
  let trimmed = points |> drop_leading |> drop_trailing |> encode_uchars in
  let normalized = Uunf_string.normalize_utf_8 `NFC trimmed in
  let normalized_points = validate_utf8 normalized in
  if List.length normalized_points < 1 || List.length normalized_points > 100 then
    invalid_name "The name must contain between 1 and 100 Unicode code points.";
  if
    List.exists
      (fun value -> Uucp.Gc.general_category value = `Cc)
      normalized_points
  then invalid_name "The name must not contain control characters.";
  normalized

let fold_utf8 text =
  let values = validate_utf8 text in
  let buffer = Buffer.create (String.length text * 2) in
  List.iter
    (fun value ->
      match Uucp.Case.Fold.fold value with
      | `Self -> encode_uchar buffer value
      | `Uchars folded -> List.iter (encode_uchar buffer) folded)
    values;
  Buffer.contents buffer

let is_mark = function `Mn | `Mc | `Me -> true | _ -> false

let is_letter_or_number = function
  | `Ll | `Lm | `Lo | `Lt | `Lu | `Nd | `Nl | `No -> true
  | _ -> false

let identity_key name =
  let display = display_name name in
  let decomposed = Uunf_string.normalize_utf_8 `NFKD display in
  let folded = decomposed |> fold_utf8 |> Uunf_string.normalize_utf_8 `NFKD in
  let points = validate_utf8 folded in
  let key = Buffer.create (String.length folded) in
  List.iter
    (fun value ->
      let category = Uucp.Gc.general_category value in
      if is_letter_or_number category && Uchar.to_int value > 127 then
        invalid_name "The name contains letters or numbers that do not fold to ASCII.";
      match Uchar.to_int value with
      | code when code >= Char.code 'a' && code <= Char.code 'z' ->
          Buffer.add_char key (Char.chr code)
      | code when code >= Char.code '0' && code <= Char.code '9' ->
          Buffer.add_char key (Char.chr code)
      | _ when is_mark category -> ()
      | _ -> ())
    points;
  let value = Buffer.contents key in
  if value = "" then invalid_name "The name must contain an ASCII letter or number.";
  value

let id_for category name =
  category_slug category ^ "-" ^ identity_key name

let sort_key tag =
  (category_order tag.category, fold_utf8 (Uunf_string.normalize_utf_8 `NFC tag.name), tag.id)

let sort_tags tags = List.sort (fun left right -> compare (sort_key left) (sort_key right)) tags

let category_json = function
  | Cuisine -> `String "cuisine"
  | Dietary_style -> `String "dietary-style"
  | Course -> `String "course"

let tag_json tag =
  `Assoc
    [
      ("id", `String tag.id);
      ("category", category_json tag.category);
      ("name", `String tag.name);
    ]

let tags_json tags = `List (List.map tag_json (sort_tags tags))

let database_failure detail =
  raise (Database_error detail)

let check_rc db action = function
  | Sqlite3.Rc.OK -> ()
  | result ->
      database_failure
        (Printf.sprintf "%s: %s (%s)" action (Sqlite3.errmsg db)
           (Sqlite3.Rc.to_string result))

let exec db sql = check_rc db sql (Sqlite3.exec db sql)

let with_statement db sql action =
  let statement = Sqlite3.prepare db sql in
  Fun.protect
    ~finally:(fun () -> ignore (Sqlite3.finalize statement))
    (fun () -> action statement)

let bind_text db statement index value =
  check_rc db "bind text"
    (Sqlite3.bind statement index (Sqlite3.Data.TEXT value))

let step db statement =
  match Sqlite3.step statement with
  | Sqlite3.Rc.ROW -> true
  | Sqlite3.Rc.DONE -> false
  | result -> check_rc db "execute statement" result; false

let column_text statement index =
  match Sqlite3.column statement index with
  | Sqlite3.Data.TEXT value -> value
  | _ -> database_failure "Expected a text column in the tags database"

let tag_of_statement statement =
  let id = column_text statement 0 in
  let category =
    match category_of_string (column_text statement 1) with
    | Some category -> category
    | None -> failwith "Invalid category stored in tags database"
  in
  { id; category; name = column_text statement 2 }

let rec ensure_directory path =
  if path <> "" && path <> "." && not (Sys.file_exists path) then (
    ensure_directory (Filename.dirname path);
    Unix.mkdir path 0o755)

let database_file = function
  | None -> "tags.sqlite"
  | Some path
    when Filename.check_suffix path ".sqlite" || Filename.check_suffix path ".db" ->
      path
  | Some directory -> Filename.concat directory "tags.sqlite"

let open_database configured_location =
  let path = database_file configured_location in
  ensure_directory (Filename.dirname path);
  let db = Sqlite3.db_open path in
  Sqlite3.busy_timeout db 5000;
  exec db "PRAGMA foreign_keys = ON";
  exec db "PRAGMA journal_mode = WAL";
  exec db
    "CREATE TABLE IF NOT EXISTS tags (\
     id TEXT PRIMARY KEY NOT NULL,\
     category TEXT NOT NULL CHECK (category IN ('cuisine', 'dietary-style', 'course')),\
     name TEXT NOT NULL)";
  exec db
    "CREATE TABLE IF NOT EXISTS assignments (\
     recipe_id TEXT NOT NULL,\
     tag_id TEXT NOT NULL REFERENCES tags(id),\
     PRIMARY KEY (recipe_id, tag_id)) WITHOUT ROWID";
  db

let close_database db = ignore (Sqlite3.db_close db)

let with_transaction db action =
  exec db "BEGIN IMMEDIATE";
  try
    let result = action () in
    exec db "COMMIT";
    result
  with error ->
    (try exec db "ROLLBACK"
     with rollback_error ->
       prerr_endline ("tags rollback error: " ^ Printexc.to_string rollback_error));
    raise error

let raise_collision name =
  raise
    (Problem
       (problem ~field:"name" 409 "Tag collision"
          "A tag with this category and normalized name already exists."
          "tag-collision"))

let create_tag db category name =
  let display = display_name name in
  let id = id_for category display in
  with_transaction db (fun () ->
      with_statement db
        "INSERT INTO tags(id, category, name) VALUES (?, ?, ?) \
         ON CONFLICT(id) DO NOTHING"
        (fun statement ->
          bind_text db statement 1 id;
          bind_text db statement 2 (category_slug category);
          bind_text db statement 3 display;
          ignore (step db statement));
      if Sqlite3.changes db = 0 then raise_collision name;
      { id; category; name = display })

let select_tags db ?category () =
  let query, bind =
    match category with
    | None ->
        ("SELECT id, category, name FROM tags", fun _ -> ())
    | Some category ->
        ( "SELECT id, category, name FROM tags WHERE category = ?",
          fun statement -> bind_text db statement 1 (category_slug category) )
  in
  with_statement db query (fun statement ->
      bind statement;
      let rec collect accumulated =
        if step db statement then
          collect (tag_of_statement statement :: accumulated)
        else sort_tags (List.rev accumulated)
      in
      collect [])

let tag_exists db id =
  with_statement db "SELECT 1 FROM tags WHERE id = ?" (fun statement ->
      bind_text db statement 1 id;
      step db statement)

let assigned_tags db recipe_id =
  with_statement db
    "SELECT tags.id, tags.category, tags.name \
     FROM assignments JOIN tags ON tags.id = assignments.tag_id \
     WHERE assignments.recipe_id = ?"
    (fun statement ->
      bind_text db statement 1 recipe_id;
      let rec collect accumulated =
        if step db statement then
          collect (tag_of_statement statement :: accumulated)
        else sort_tags (List.rev accumulated)
      in
      collect [])

let unknown_tag tag_id =
  raise
    (Problem
       (problem ~field:"tagId" 404 "Tag not found"
          "The requested tag does not exist." "tag-not-found"))

let assign_one db recipe_id tag_id =
  with_transaction db (fun () ->
      if not (tag_exists db tag_id) then unknown_tag tag_id;
      with_statement db
        "INSERT INTO assignments(recipe_id, tag_id) VALUES (?, ?) \
         ON CONFLICT(recipe_id, tag_id) DO NOTHING"
        (fun statement ->
          bind_text db statement 1 recipe_id;
          bind_text db statement 2 tag_id;
          ignore (step db statement)))

let remove_one db recipe_id tag_id =
  with_transaction db (fun () ->
      with_statement db
        "DELETE FROM assignments WHERE recipe_id = ? AND tag_id = ?"
        (fun statement ->
          bind_text db statement 1 recipe_id;
          bind_text db statement 2 tag_id;
          ignore (step db statement)))

let normalize_ids field = function
  | None -> []
  | Some (`List values) ->
      let ids =
        List.map
          (function
            | `String value when value <> "" -> value
            | _ -> invalid_ids ~field "Each ID must be a non-empty string.")
          values
      in
      List.sort_uniq String.compare ids
  | Some _ -> invalid_ids ~field "The value must be an array of tag IDs."

let bulk_change db recipe_id add_ids remove_ids =
  let add_ids = List.sort_uniq String.compare add_ids in
  let remove_ids = List.sort_uniq String.compare remove_ids in
  if List.exists (fun id -> List.mem id remove_ids) add_ids then
    raise
      (Problem
         (problem 422 "Conflicting tag change"
            "A tag ID cannot be added and removed in the same request."
            "conflicting-tag-change"));
  with_transaction db (fun () ->
      let check_ids field ids =
        List.iter
          (fun id ->
            if not (tag_exists db id) then
              raise
                (Problem
                   (problem ~field 422 "Unknown tag"
                      "The tag ID does not exist in the inventory."
                      "unknown-tag")))
          ids
      in
      check_ids "addTagIds" add_ids;
      check_ids "removeTagIds" remove_ids;
      List.iter
        (fun id ->
          with_statement db
            "INSERT INTO assignments(recipe_id, tag_id) VALUES (?, ?) \
             ON CONFLICT(recipe_id, tag_id) DO NOTHING"
            (fun statement ->
              bind_text db statement 1 recipe_id;
              bind_text db statement 2 id;
              ignore (step db statement)))
        add_ids;
      List.iter
        (fun id ->
          with_statement db
            "DELETE FROM assignments WHERE recipe_id = ? AND tag_id = ?"
            (fun statement ->
              bind_text db statement 1 recipe_id;
              bind_text db statement 2 id;
              ignore (step db statement)))
        remove_ids;
      assigned_tags db recipe_id)

let delete_tag db tag_id =
  with_transaction db (fun () ->
      if not (tag_exists db tag_id) then unknown_tag tag_id;
      let count =
        with_statement db
          "SELECT COUNT(*) FROM assignments WHERE tag_id = ?"
          (fun statement ->
            bind_text db statement 1 tag_id;
            if step db statement then
              match Sqlite3.column statement 0 with
              | Sqlite3.Data.INT count -> count
              | _ -> database_failure "Expected an assignment count"
            else database_failure "Missing assignment count")
      in
      if count > 0L then
        raise
          (Problem
             (problem ~field:"tagId" 409 "Tag is in use"
                "The tag is assigned to one or more recipes." "tag-in-use"));
      with_statement db "DELETE FROM tags WHERE id = ?" (fun statement ->
          bind_text db statement 1 tag_id;
          ignore (step db statement)))

let reset_database db =
  with_transaction db (fun () ->
      exec db "DELETE FROM assignments";
      exec db "DELETE FROM tags")

let category_parameter request =
  match Dream.query request "category" with
  | None -> None
  | Some value -> (
      match category_of_string value with
      | Some category -> Some category
      | None ->
          raise
            (Problem
               (problem ~field:"category" 422 "Invalid category"
                  "The category must be cuisine, dietary-style, or course."
                  "invalid-category")))

let json_response ?(status = 200) json =
  Dream.response ~status:(Dream.int_to_status status)
    ~headers:[ ("Content-Type", "application/json") ]
    (Yojson.Basic.to_string json)

let problem_response ?(headers = []) problem =
  let fields =
    [
      ("type", `String "about:blank");
      ("title", `String problem.title);
      ("status", `Int problem.status);
      ("detail", `String problem.detail);
      ("code", `String problem.code);
    ]
  in
  let fields =
    match problem.field with
    | None -> fields
    | Some field -> fields @ [ ("field", `String field) ]
  in
  Dream.response ~status:(Dream.int_to_status problem.status)
    ~headers:(("Content-Type", "application/problem+json") :: headers)
    (Yojson.Basic.to_string (`Assoc fields))

let decode_segment segment =
  let buffer = Buffer.create (String.length segment) in
  let rec loop index =
    if index >= String.length segment then Buffer.contents buffer
    else if segment.[index] <> '%' then (
      Buffer.add_char buffer segment.[index];
      loop (index + 1))
    else if index + 2 >= String.length segment then
      invalid_request "The URL contains an invalid encoded path segment."
    else
      let is_hex = function
        | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
        | _ -> false
      in
      if not (is_hex segment.[index + 1] && is_hex segment.[index + 2]) then
        invalid_request "The URL contains an invalid encoded path segment."
      else
        let byte = int_of_string ("0x" ^ String.sub segment (index + 1) 2) in
        Buffer.add_char buffer (Char.chr byte);
        loop (index + 3)
  in
  loop 0

let raw_path request =
  let target = Dream.target request in
  match String.index_opt target '?' with
  | None -> target
  | Some index -> String.sub target 0 index

let path_segments request =
  raw_path request |> String.split_on_char '/'
  |> List.filteri (fun index _ -> index > 0)
  |> List.map decode_segment

let object_fields json =
  match json with
  | `Assoc fields ->
      let rec validate seen = function
        | [] -> fields
        | (name, _) :: rest ->
            if List.mem name seen then
              invalid_request ~field:name "The field must not be repeated.";
            validate (name :: seen) rest
      in
      validate [] fields
  | _ -> invalid_request "The request body must be a JSON object."

let string_field field fields =
  match List.assoc_opt field fields with
  | Some (`String value) -> value
  | Some _ -> invalid_request ~field "The field must be a string."
  | None -> invalid_request ~field "The field is required."

let reject_unknown_fields fields allowed =
  match List.find_opt (fun (name, _) -> not (List.mem name allowed)) fields with
  | Some (name, _) -> invalid_request ~field:name "The field is not allowed."
  | None -> ()

let request_json request =
  let unsupported_media_type =
    problem 415 "Unsupported media type"
      "The request must use application/json." "unsupported-media-type"
  in
  match Dream.header request "content-type" with
  | None -> Lwt.return (Error unsupported_media_type)
  | Some content_type ->
      let media_type =
        String.split_on_char ';' content_type |> List.hd |> String.trim
        |> String.lowercase_ascii
      in
      if media_type <> "application/json" then
        Lwt.return (Error unsupported_media_type)
      else
            Dream.body request >|= fun body ->
            try Ok (Yojson.Basic.from_string body)
            with Yojson.Json_error _ ->
              Error
                (problem 400 "Invalid JSON" "The request body is not valid JSON."
                   "invalid-json")

let method_not_allowed allowed =
  problem_response
    ~headers:[ ("Allow", String.concat ", " allowed) ]
    (problem 405 "Method Not Allowed"
       "The request method is not allowed for this route."
       "method-not-allowed")

let not_found () =
  problem_response
    (problem 404 "Not Found" "The requested route was not found." "not-found")

let handle mode db request =
  let method_ = Dream.method_ request |> Dream.method_to_string in
  let segments = path_segments request in
  let allowed methods =
    if List.mem method_ methods then None else Some (method_not_allowed methods)
  in
  let respond operation =
    try operation () with
    | Problem problem -> Lwt.return (problem_response problem)
    | Database_error detail ->
        prerr_endline ("tags database error: " ^ detail);
        Lwt.return
          (problem_response
             (problem 500 "Database error"
                "The tags database operation failed." "database-error"))
    | error ->
        prerr_endline ("tags server error: " ^ Printexc.to_string error);
        Lwt.return
          (problem_response
             (problem 500 "Internal Server Error"
                "An unexpected server error occurred." "internal-error"))
  in
  let with_json request operation =
    request_json request >>= function
    | Error problem -> Lwt.return (problem_response problem)
    | Ok json -> respond (fun () -> operation json)
  in
  let empty () = Dream.empty `No_Content in
  match segments with
  | [ "health" ] -> (
      match allowed [ "GET" ] with
      | Some response -> Lwt.return response
      | None ->
          (try
             with_statement db "SELECT 1" (fun statement ->
                 ignore (step db statement));
             empty ()
           with
          | Database_error detail ->
              prerr_endline ("tags health database error: " ^ detail);
               Lwt.return
                 (problem_response
                    (problem 503 "Database unavailable"
                       "The tags database is unavailable."
                       "database-unavailable"))
          | error ->
              prerr_endline ("tags health error: " ^ Printexc.to_string error);
               Lwt.return
                 (problem_response
                    (problem 503 "Database unavailable"
                       "The tags database is unavailable."
                       "database-unavailable"))))
  | [ "tags" ] | [ "tags"; "" ] -> (
      match method_ with
      | "GET" ->
          respond (fun () ->
              json_response
                (tags_json (select_tags db ?category:(category_parameter request) ()))
              |> Lwt.return)
      | "POST" ->
          with_json request (fun json ->
              let fields = object_fields json in
              reject_unknown_fields fields [ "category"; "name" ];
              let category_string = string_field "category" fields in
              let category =
                match category_of_string category_string with
                | Some category -> category
                | None ->
                    raise
                      (Problem
                         (problem ~field:"category" 422 "Invalid category"
                            "The category must be cuisine, dietary-style, or course."
                            "invalid-category"))
              in
              let name = string_field "name" fields in
              let tag = create_tag db category name in
               json_response ~status:201 (tag_json tag) |> Lwt.return)
      | "DELETE" ->
          if
            mode <> Testing
          then
             Lwt.return (not_found ())
          else respond (fun () -> reset_database db; empty ())
       | _ -> Lwt.return (method_not_allowed [ "GET"; "POST"; "DELETE" ]))
  | [ "tags"; "recipes"; recipe_id ] -> (
      match method_ with
      | "GET" ->
          respond (fun () ->
              json_response (tags_json (assigned_tags db recipe_id))
              |> Lwt.return)
      | "PATCH" ->
          with_json request (fun json ->
              let fields = object_fields json in
              reject_unknown_fields fields [ "addTagIds"; "removeTagIds" ];
              let add_ids = normalize_ids "addTagIds" (List.assoc_opt "addTagIds" fields) in
              let remove_ids =
                normalize_ids "removeTagIds" (List.assoc_opt "removeTagIds" fields)
              in
              json_response
                 (tags_json (bulk_change db recipe_id add_ids remove_ids))
               |> Lwt.return)
       | _ -> Lwt.return (method_not_allowed [ "GET"; "PATCH" ]))
  | [ "tags"; "recipes"; recipe_id; "assignments"; tag_id ] -> (
      match method_ with
      | "PUT" ->
          respond (fun () ->
              assign_one db recipe_id tag_id;
              empty ())
      | "DELETE" ->
          respond (fun () ->
              remove_one db recipe_id tag_id;
              empty ())
       | _ -> Lwt.return (method_not_allowed [ "PUT"; "DELETE" ]))
  | [ "tags"; tag_id ] -> (
      match allowed [ "DELETE" ] with
      | Some response -> Lwt.return response
      | None ->
          respond (fun () ->
              delete_tag db tag_id;
              empty ()))
  | _ -> Lwt.return (not_found ())

let router ~mode db =
  let handler = Dream.router
    [
      Dream.any "/" (handle mode db);
      Dream.any "/**" (handle mode db);
    ]
  in
  fun request ->
    Lwt.catch
      (fun () -> handler request)
      (function
        | Problem problem -> Lwt.return (problem_response problem)
        | error ->
            prerr_endline ("tags server error: " ^ Printexc.to_string error);
            Lwt.return
              (problem_response
                 (problem 500 "Internal Server Error"
                    "An unexpected server error occurred." "internal-error")))
