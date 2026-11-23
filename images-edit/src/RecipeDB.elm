module RecipeDB exposing (Capabilities, CapabilitiesModel, DeleteModel, GalleryImage, RecipeData, RecipeModel, ReorderModel, ReorderResult(..), UploadModel, UploadedImage, decodeDeleteImage, decodeReorderImages, decodeUpload, makeCapabilitiesRequest, makeDeleteImageRequest, makeRecipeRequest, makeReorderImagesRequest, makeUploadRequest)

import Api.Object exposing (Recipe)
import Api.Object.ImageMetadata as ImageMetadata
import Api.Object.MyCapabilities as MyCapabilities
import Api.Object.Recipe as Recipe
import Api.Query as Query
import Api.Scalar exposing (Id(..))
import Crop exposing (Crop)
import File exposing (File)
import Graphql.Http
import Graphql.Operation exposing (RootQuery)
import Graphql.SelectionSet as SelectionSet exposing (SelectionSet)
import Http
import Json.Decode as Decode exposing (field, int, map5, string)
import Json.Encode as Encode
import RemoteData exposing (RemoteData)


type alias RecipeData =
    { name : String
    , images : Maybe (List GalleryImage)
    }


type alias GalleryImage =
    { id : String
    , thumbUrl : String
    }


type alias RecipeModel =
    RemoteData (Graphql.Http.Error (Maybe RecipeData)) (Maybe RecipeData)


type alias Capabilities =
    { role : String
    , canManageImages : Bool
    , maintenance : Bool
    }


type alias CapabilitiesModel =
    RemoteData (Graphql.Http.Error Capabilities) Capabilities


makeCapabilitiesRequest : (CapabilitiesModel -> msg) -> Cmd msg
makeCapabilitiesRequest targetMsg =
    let
        selection : SelectionSet Capabilities Api.Object.MyCapabilities
        selection =
            SelectionSet.map2 (\role canManageImages -> { role = role, canManageImages = canManageImages, maintenance = False })
                MyCapabilities.role
                MyCapabilities.canManageImages

        query : SelectionSet Capabilities RootQuery
        query =
            SelectionSet.map2
                (\maintenance capabilities -> { capabilities | maintenance = maintenance })
                Query.maintenance
                (Query.myCapabilities selection)
    in
    query
        |> Graphql.Http.queryRequest "/graphql"
        |> Graphql.Http.send (RemoteData.fromResult >> targetMsg)


makeRecipeRequest : String -> (RecipeModel -> msg) -> Cmd msg
makeRecipeRequest recipeId targetMsg =
    let
        selection : SelectionSet RecipeData Recipe
        selection =
            SelectionSet.map2 RecipeData
                Recipe.name
                (Recipe.images
                    (SelectionSet.map2 GalleryImage
                        (SelectionSet.map (\(Id id) -> id) ImageMetadata.id)
                        ImageMetadata.thumbUrl
                    )
                )

        recipeQuery : SelectionSet (Maybe RecipeData) RootQuery
        recipeQuery =
            Query.recipe { id = Id recipeId } selection
    in
    recipeQuery
        |> Graphql.Http.queryRequest "/graphql"
        |> Graphql.Http.send (RemoteData.fromResult >> targetMsg)


type alias UploadModel =
    RemoteData.RemoteData String UploadedImage


type alias DeleteModel =
    RemoteData.RemoteData String Bool


type ReorderResult
    = ReorderConfirmed
    | ReorderRejected String
    | ReorderUnconfirmed String


type alias ReorderModel =
    RemoteData.RemoteData String ReorderResult


type alias UploadedImage =
    { url : String
    , thumbUrl : String
    , size : Int
    , width : Int
    , height : Int
    }


makeUploadRequest : String -> File -> Crop -> (UploadModel -> msg) -> Cmd msg
makeUploadRequest recipeId file crop targetMsg =
    let
        query : String
        query =
            -- per the GraphQL multipart request spec, "variables" must already contain a `null`
            -- placeholder for every Upload variable the "map" below then overwrites
            Encode.object
                [ ( "query"
                  , Encode.string "mutation ($recipeId: ID!, $file: Upload!, $crop: ImageCropInput!) { addImage(recipeId: $recipeId, file: $file, crop: $crop) { url thumbUrl size width height } }"
                  )
                , ( "variables"
                  , Encode.object
                        [ ( "recipeId", Encode.string recipeId )
                        , ( "file", Encode.null )
                        , ( "crop"
                          , Encode.object
                                [ ( "x", Encode.int crop.x )
                                , ( "y", Encode.int crop.y )
                                , ( "width", Encode.int crop.width )
                                , ( "height", Encode.int crop.height )
                                ]
                          )
                        ]
                  )
                ]
                |> Encode.encode 0

        map : String
        map =
            "{ \"0\": [\"variables.file\"] }"

        body : Http.Body
        body =
            Http.multipartBody
                [ Http.stringPart "operations" query
                , Http.stringPart "map" map
                , Http.filePart "0" file
                ]

        headers : List Http.Header
        headers =
            [ Http.header "apollo-require-preflight" "true"
            ]
    in
    Http.request
        { method = "POST"
        , headers = headers
        , url = "/graphql"
        , body = body
        , timeout = Nothing
        , tracker = Nothing
        , expect =
            Http.expectString
                (\result ->
                    result
                        |> Result.mapError transportError
                        |> Result.andThen decodeUpload
                        |> RemoteData.fromResult
                        |> targetMsg
                )
        }


transportError : Http.Error -> String
transportError error =
    case error of
        Http.NetworkError ->
            "Keine Verbindung zum Server. Bitte die Verbindung prüfen und erneut speichern."

        Http.Timeout ->
            "Zeitüberschreitung beim Speichern. Bitte erneut versuchen."

        Http.BadStatus 413 ->
            "Die Datei ist für den Server zu groß. Bitte ein kleineres Bild auswählen."

        Http.BadStatus 401 ->
            "authentication-required"

        Http.BadStatus 403 ->
            "forbidden"

        _ ->
            "Speichern fehlgeschlagen. Bitte später erneut versuchen."


makeDeleteImageRequest : String -> String -> (DeleteModel -> msg) -> Cmd msg
makeDeleteImageRequest recipeId imageId targetMsg =
    let
        body : String
        body =
            Encode.object
                [ ( "query", Encode.string "mutation ($recipeId: ID!, $imageId: ID!) { deleteImage(recipeId: $recipeId, imageId: $imageId) }" )
                , ( "variables"
                  , Encode.object
                        [ ( "recipeId", Encode.string recipeId )
                        , ( "imageId", Encode.string imageId )
                        ]
                  )
                ]
                |> Encode.encode 0
    in
    Http.request
        { method = "POST"
        , headers = []
        , url = "/graphql"
        , body = Http.stringBody "application/json" body
        , timeout = Nothing
        , tracker = Nothing
        , expect =
            Http.expectString
                (\result ->
                    result
                        |> Result.mapError deleteTransportError
                        |> Result.andThen decodeDeleteImage
                        |> RemoteData.fromResult
                        |> targetMsg
                )
        }


deleteTransportError : Http.Error -> String
deleteTransportError error =
    case error of
        Http.BadStatus 401 ->
            "Anmeldung erforderlich oder abgelaufen. Die Löschung konnte nicht bestätigt werden."

        Http.BadStatus 403 ->
            "Keine Berechtigung zum Verwalten dieses Bildes. Die Löschung konnte nicht bestätigt werden."

        _ ->
            "Die Löschung konnte nicht bestätigt werden."


makeReorderImagesRequest : String -> List String -> (ReorderModel -> msg) -> Cmd msg
makeReorderImagesRequest recipeId imageIds targetMsg =
    let
        body : String
        body =
            Encode.object
                [ ( "query"
                  , Encode.string
                        "mutation ($recipeId: ID!, $imageIds: [ID!]!) { reorderImages(recipeId: $recipeId, imageIds: $imageIds) { id url thumbUrl size width height } }"
                  )
                , ( "variables"
                  , Encode.object
                        [ ( "recipeId", Encode.string recipeId )
                        , ( "imageIds", Encode.list Encode.string imageIds )
                        ]
                  )
                ]
                |> Encode.encode 0
    in
    Http.request
        { method = "POST"
        , headers = []
        , url = "/graphql"
        , body = Http.stringBody "application/json" body
        , timeout = Nothing
        , tracker = Nothing
        , expect =
            Http.expectString
                (\result ->
                    (case result of
                        Ok payload ->
                            decodeReorderImages imageIds payload

                        Err error ->
                            reorderTransportError error
                    )
                        |> RemoteData.fromResult
                        |> targetMsg
                )
        }


reorderTransportError : Http.Error -> Result String ReorderResult
reorderTransportError error =
    case error of
        Http.BadStatus 401 ->
            Ok (ReorderRejected "Anmeldung erforderlich oder abgelaufen. Die Reihenfolge wurde nicht geändert.")

        Http.BadStatus 403 ->
            Ok (ReorderRejected "Keine Berechtigung zum Verwalten dieses Bildes. Die Reihenfolge wurde nicht geändert.")

        _ ->
            Ok (ReorderUnconfirmed "Die Änderung der Bildreihenfolge konnte nicht bestätigt werden. Der aktuelle Stand wird neu geladen.")


decodeReorderImages : List String -> String -> Result String ReorderResult
decodeReorderImages imageIds body =
    Decode.decodeString Decode.value body
        |> Result.mapError (\_ -> "Die Änderung der Bildreihenfolge konnte nicht bestätigt werden. Der aktuelle Stand wird neu geladen.")
        |> Result.andThen (decodeReorderResponse imageIds)


decodeReorderResponse : List String -> Decode.Value -> Result String ReorderResult
decodeReorderResponse imageIds value =
    case Decode.decodeValue (field "errors" Decode.value) value of
        Ok errors ->
            case Decode.decodeValue (Decode.list Decode.value) errors of
                Ok (first :: _) ->
                    Ok (reorderGraphQLError first)

                Ok [] ->
                    decodeReorderSuccess imageIds value

                Err _ ->
                    reorderResponseUnconfirmed

        Err _ ->
            decodeReorderSuccess imageIds value


decodeReorderSuccess : List String -> Decode.Value -> Result String ReorderResult
decodeReorderSuccess imageIds value =
    Decode.decodeValue (field "data" (field "reorderImages" reorderMetadata)) value
        |> Result.mapError (\_ -> "Die Änderung der Bildreihenfolge konnte nicht bestätigt werden. Der aktuelle Stand wird neu geladen.")
        |> Result.andThen
            (\returnedIds ->
                if returnedIds == imageIds then
                    Ok ReorderConfirmed

                else
                    reorderResponseUnconfirmed
            )


reorderResponseUnconfirmed : Result String ReorderResult
reorderResponseUnconfirmed =
    Err "Die Änderung der Bildreihenfolge konnte nicht bestätigt werden. Der aktuelle Stand wird neu geladen."


reorderMetadata : Decode.Decoder (List String)
reorderMetadata =
    Decode.list
        (Decode.map6
            (\id _ _ _ _ _ -> id)
            (field "id" string)
            (field "url" string)
            (field "thumbUrl" string)
            (field "size" int)
            (field "width" int)
            (field "height" int)
        )


reorderGraphQLError : Decode.Value -> ReorderResult
reorderGraphQLError value =
    case Decode.decodeValue (Decode.at [ "extensions", "code" ] string) value of
        Ok "maintenance-mode" ->
            ReorderRejected "Wartungsarbeiten: Änderungen sind vorübergehend nicht möglich. Lesen bleibt verfügbar."

        Ok "image-order-conflict" ->
            ReorderRejected "Die Bildreihenfolge wurde zwischenzeitlich geändert. Der aktuelle Stand wird neu geladen."

        Ok "invalid-image-order" ->
            ReorderRejected "Die Bildreihenfolge wurde abgelehnt, weil sich die Bildauswahl geändert hat. Der aktuelle Stand wird neu geladen."

        Ok "authentication-required" ->
            ReorderRejected "Anmeldung erforderlich oder abgelaufen. Die Reihenfolge wurde nicht geändert."

        Ok "forbidden" ->
            ReorderRejected "Keine Berechtigung zum Verwalten dieses Bildes. Die Reihenfolge wurde nicht geändert."

        _ ->
            ReorderUnconfirmed "Die Änderung der Bildreihenfolge konnte nicht bestätigt werden. Der aktuelle Stand wird neu geladen."


decodeDeleteImage : String -> Result String Bool
decodeDeleteImage body =
    Decode.decodeString Decode.value body
        |> Result.mapError (\_ -> "Der Server hat eine ungültige Löschantwort gesendet.")
        |> Result.andThen decodeDeleteResponse


decodeDeleteResponse : Decode.Value -> Result String Bool
decodeDeleteResponse value =
    case Decode.decodeValue (field "errors" Decode.value) value of
        Ok errors ->
            case Decode.decodeValue (Decode.list Decode.value) errors of
                Ok [] ->
                    decodeDeletedValue value

                Ok (first :: _) ->
                    Err (deleteGraphQLError first)

                Err _ ->
                    Err "Der Server hat eine ungültige GraphQL-Fehlerantwort gesendet."

        Err _ ->
            decodeDeletedValue value


decodeDeletedValue : Decode.Value -> Result String Bool
decodeDeletedValue value =
    Decode.decodeValue (field "data" (field "deleteImage" Decode.bool)) value
        |> Result.mapError (\_ -> "Der Server hat das Ergebnis der Löschung nicht bestätigt.")


deleteGraphQLError : Decode.Value -> String
deleteGraphQLError value =
    case Decode.decodeValue (Decode.at [ "extensions", "code" ] string) value of
        Ok "maintenance-mode" ->
            "Wartungsarbeiten: Änderungen sind vorübergehend nicht möglich. Lesen bleibt verfügbar."

        Ok "authentication-required" ->
            "Anmeldung erforderlich oder abgelaufen. Die Löschung konnte nicht bestätigt werden."

        Ok "invalid-credentials" ->
            "Anmeldung erforderlich oder abgelaufen. Die Löschung konnte nicht bestätigt werden."

        Ok "invalid-auth-context" ->
            "Anmeldung erforderlich oder abgelaufen. Die Löschung konnte nicht bestätigt werden."

        Ok "mixed-auth-context" ->
            "Anmeldung erforderlich oder abgelaufen. Die Löschung konnte nicht bestätigt werden."

        Ok "forbidden" ->
            "Keine Berechtigung zum Verwalten dieses Bildes. Die Löschung konnte nicht bestätigt werden."

        Ok "csrf-forbidden" ->
            "Keine Berechtigung zum Verwalten dieses Bildes. Die Löschung konnte nicht bestätigt werden."

        Ok "invalid-image-id" ->
            "Die Bildkennung ist ungültig. Die Löschung konnte nicht bestätigt werden."

        Ok "invalid-recipe-id" ->
            "Das Rezept konnte nicht gefunden werden. Die Löschung konnte nicht bestätigt werden."

        _ ->
            "Die Löschung konnte nicht bestätigt werden."


decodeUpload : String -> Result String UploadedImage
decodeUpload body =
    case Decode.decodeString Decode.value body of
        Err _ ->
            Err "Die Serverantwort konnte nicht gelesen werden. Bitte erneut speichern."

        Ok value ->
            case Decode.decodeValue (field "errors" Decode.value) value of
                Ok errors ->
                    case Decode.decodeValue (Decode.list Decode.value) errors of
                        Ok [] ->
                            decodeMetadata value

                        Ok (first :: _) ->
                            Err (graphQLError first)

                        Err _ ->
                            Err "Der Server hat eine ungültige Fehlerantwort gesendet. Bitte erneut speichern."

                Err _ ->
                    decodeMetadata value


decodeMetadata : Decode.Value -> Result String UploadedImage
decodeMetadata value =
    Decode.decodeValue
        (field "data"
            (field "addImage"
                (map5 UploadedImage
                    (field "url" string)
                    (field "thumbUrl" string)
                    (field "size" int)
                    (field "width" int)
                    (field "height" int)
                )
            )
        )
        value
        |> Result.mapError (\_ -> "Der Server hat das gespeicherte Bild nicht bestätigt. Bitte erneut speichern.")


graphQLError : Decode.Value -> String
graphQLError value =
    case Decode.decodeValue (Decode.at [ "extensions", "code" ] string) value of
        Ok "maintenance-mode" ->
            "maintenance-mode"

        Ok "authentication-required" ->
            "authentication-required"

        Ok "invalid-credentials" ->
            "authentication-required"

        Ok "invalid-auth-context" ->
            "authentication-required"

        Ok "mixed-auth-context" ->
            "authentication-required"

        Ok "forbidden" ->
            "forbidden"

        Ok "csrf-forbidden" ->
            "forbidden"

        Ok "crop-out-of-bounds" ->
            "Der Zuschnitt liegt außerhalb des Bildes. Bitte den Zuschnitt anpassen und erneut speichern."

        Ok "crop-too-small" ->
            "Der Zuschnitt ist zu klein. Mindestens 300 × 225 Pixel sind erforderlich."

        Ok "invalid-crop-aspect-ratio" ->
            "Der Zuschnitt muss das Seitenverhältnis 4:3 haben. Bitte den Zuschnitt anpassen."

        Ok "invalid-crop" ->
            "Der Zuschnitt wurde ungültig übertragen. Bitte den Zuschnitt anpassen und erneut speichern."

        Ok "incomplete-crop" ->
            "Der Zuschnitt wurde nicht vollständig übertragen. Bitte erneut speichern."

        Ok "image-too-large" ->
            "Das Bild überschreitet die erlaubte Datei- oder Pixelgröße des Servers. Bitte ein kleineres Bild auswählen."

        Ok "image-limit-reached" ->
            "Das Rezept hat bereits die maximal erlaubten zehn Bilder. Das Bild wurde nicht gespeichert."

        Ok "unsupported-content-type" ->
            "Dieses Dateiformat wird nicht unterstützt. Bitte eine JPEG- oder PNG-Datei auswählen."

        Ok "invalid-image" ->
            "Das Bild konnte nicht verarbeitet werden. Bitte eine unbeschädigte JPEG- oder PNG-Datei auswählen."

        Ok "storage-error" ->
            "Das Bild konnte auf dem Server nicht gespeichert werden. Bitte später erneut versuchen."

        _ ->
            "Das Bild konnte nicht gespeichert werden. Bitte Dateiformat und Zuschnitt prüfen und erneut versuchen."
