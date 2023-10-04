module RecipeDB exposing (RecipeData, RecipeModel, UploadModel, makeRecipeRequest, makeUploadRequest)

import Api.Object exposing (Recipe)
import Api.Object.ImageMetadata as ImageMetadata
import Api.Object.Recipe as Recipe
import Api.Query as Query
import Api.Scalar exposing (Id(..))
import File exposing (File)
import Graphql.Http
import Graphql.Operation exposing (RootQuery)
import Graphql.SelectionSet as SelectionSet exposing (SelectionSet)
import Http
import Json.Decode exposing (Decoder, bool, field, null, oneOf)
import RemoteData exposing (RemoteData)


type alias RecipeData =
    { name : String
    , thumbUrl : Maybe String
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
                (Recipe.image ImageMetadata.thumbUrl)

        recipeQuery : SelectionSet (Maybe RecipeData) RootQuery
        recipeQuery =
            Query.recipe { id = Id recipeId } selection
    in
    recipeQuery
        |> Graphql.Http.queryRequest "/graphql"
        |> Graphql.Http.send (RemoteData.fromResult >> targetMsg)


type alias UploadModel =
    RemoteData.RemoteData Http.Error Bool


makeUploadRequest : String -> File -> (UploadModel -> msg) -> Cmd msg
makeUploadRequest recipeId file targetMsg =
    let
        query : String
        query =
            "{ \"query\": \"mutation ($file: Upload!) { setImage(recipeId: \\\"" ++ recipeId ++ "\\\", file: $file) }\" }"

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

        uploadImageDecoder : Decoder Bool
        uploadImageDecoder =
            field "data" (oneOf [ null False, field "setImage" bool ])
    in
    Http.request
        { method = "POST"
        , headers = headers
        , url = "/graphql"
        , body = body
        , timeout = Nothing
        , tracker = Nothing
        , expect = Http.expectJson (RemoteData.fromResult >> targetMsg) uploadImageDecoder
        }
