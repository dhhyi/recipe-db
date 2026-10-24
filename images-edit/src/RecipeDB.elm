module RecipeDB exposing (RecipeData, RecipeModel, UploadModel, UploadedImage, decodeUpload, makeRecipeRequest, makeUploadRequest)

import Api.Object exposing (Recipe)
import Api.Object.ImageMetadata as ImageMetadata
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
    , url : Maybe String
    }


type alias RecipeModel =
    RemoteData (Graphql.Http.Error (Maybe RecipeData)) (Maybe RecipeData)


makeRecipeRequest : String -> (RecipeModel -> msg) -> Cmd msg
makeRecipeRequest recipeId targetMsg =
    let
        selection : SelectionSet RecipeData Recipe
        selection =
            SelectionSet.map2 RecipeData
                Recipe.name
                (Recipe.image ImageMetadata.url)

        recipeQuery : SelectionSet (Maybe RecipeData) RootQuery
        recipeQuery =
            Query.recipe { id = Id recipeId } selection
    in
    recipeQuery
        |> Graphql.Http.queryRequest "/graphql"
        |> Graphql.Http.send (RemoteData.fromResult >> targetMsg)


type alias UploadModel =
    RemoteData.RemoteData String UploadedImage


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
                  , Encode.string "mutation ($recipeId: ID!, $file: Upload!, $crop: ImageCropInput!) { setImage(recipeId: $recipeId, file: $file, crop: $crop) { url thumbUrl size width height } }"
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

        _ ->
            "Speichern fehlgeschlagen. Bitte später erneut versuchen."


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
            (field "setImage"
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

        Ok "unsupported-content-type" ->
            "Dieses Dateiformat wird nicht unterstützt. Bitte eine JPEG- oder PNG-Datei auswählen."

        Ok "invalid-image" ->
            "Das Bild konnte nicht verarbeitet werden. Bitte eine unbeschädigte JPEG- oder PNG-Datei auswählen."

        Ok "storage-error" ->
            "Das Bild konnte auf dem Server nicht gespeichert werden. Bitte später erneut versuchen."

        _ ->
            "Das Bild konnte nicht gespeichert werden. Bitte Dateiformat und Zuschnitt prüfen und erneut versuchen."
