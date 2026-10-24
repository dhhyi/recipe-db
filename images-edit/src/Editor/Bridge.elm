port module Editor.Bridge exposing (Incoming(..), command, events, incoming, release)

import Crop exposing (Point, Size)
import Json.Decode as D
import Json.Encode as E


port editorCommand : E.Value -> Cmd msg


port editorEvent : (D.Value -> msg) -> Sub msg


type Incoming
    = Metadata Int Size
    | Loaded Int String Size Size
    | LoadFailed Int
    | Pointer String String Point { width : Float, height : Float }
    | EndPointer


command : String -> List ( String, E.Value ) -> Cmd msg
command action fields =
    editorCommand (E.object (( "action", E.string action ) :: fields))


release : Int -> Cmd msg
release token =
    command "release" [ ( "token", E.int token ) ]


events : (D.Value -> msg) -> Sub msg
events =
    editorEvent


incoming : D.Decoder Incoming
incoming =
    D.field "kind" D.string
        |> D.andThen
            (\kind ->
                case kind of
                    "metadata" ->
                        D.map2 Metadata (D.field "token" D.int) size

                    "loaded" ->
                        D.map4 Loaded
                            (D.field "token" D.int)
                            (D.field "url" D.string)
                            size
                            (D.map2 Size (D.field "naturalWidth" D.int) (D.field "naturalHeight" D.int))

                    "failed" ->
                        D.map LoadFailed (D.field "token" D.int)

                    "pointer" ->
                        D.map4 Pointer
                            (D.field "event" D.string)
                            (D.field "handle" D.string)
                            (D.map2 Point (D.field "x" D.float) (D.field "y" D.float))
                            (D.map2 (\width height -> { width = width, height = height }) (D.field "displayWidth" D.float) (D.field "displayHeight" D.float))

                    "end" ->
                        D.succeed EndPointer

                    _ ->
                        D.fail "Unbekanntes Editorereignis"
            )


size : D.Decoder Size
size =
    D.map2 Size (D.field "width" D.int) (D.field "height" D.int)
