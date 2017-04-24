module Api
    exposing
        ( facebookAuthUrl
        , Msg(..)
        , authenticate
        , getMe
        , createProposal
        , supportProposal
        , getProposal
        , getProposalList
        )

import Result.Extra
import Http
import Task exposing (Task)
import Json.Decode as Decode
import Json.Decode exposing (Decoder)
import Json.Encode as Encode
import JsonApi
import JsonApi.Resources
import JsonApi.Documents
import JsonApi.Extra
import Api.Util exposing ((:>))
import Types exposing (..)
import Config


type Msg
    = GotAccessToken String
    | AuthFailed Http.Error
    | ProposalCreated Proposal
    | ProposalCreationFailed Http.Error
    | ProposalSupported Support
    | ProposalUnsupported String
    | SupportProposalFailed Http.Error
    | GotProposal Proposal
    | GettingProposalFailed Http.Error
    | GotProposalList ProposalList
    | GettingProposalListFailed Http.Error
    | GotMe Me



-- ENDPOINTS


tokenEndpoint : String
tokenEndpoint =
    Config.apiUrl ++ "/token"


meEndpoint : String
meEndpoint =
    Config.apiUrl ++ "/me"


newProposalEndpoint : String
newProposalEndpoint =
    Config.apiUrl ++ "/proposals"


supportProposalEndpoint : String
supportProposalEndpoint =
    Config.apiUrl ++ "/supports"


unsupportProposalEndpoint : String -> String
unsupportProposalEndpoint id =
    Config.apiUrl ++ "/proposals/" ++ id ++ "/support"


getProposalEndpoint : String -> String
getProposalEndpoint id =
    Config.apiUrl ++ "/proposals/" ++ id


getProposalListEndpoint : String
getProposalListEndpoint =
    Config.apiUrl ++ "/proposals"


facebookAuthUrl : String
facebookAuthUrl =
    let
        facebookRedirectUri =
            Config.baseRoot
                ++ Config.basePath
                ++ "/"
                ++ Config.facebookRedirectPath
    in
        "https://www.facebook.com/dialog/oauth?client_id="
            ++ Config.facebookClientId
            ++ "&redirect_uri="
            ++ facebookRedirectUri



-- DECODERS & ENCODERS


decodeToken : Decoder String
decodeToken =
    Decode.at [ "access_token" ] Decode.string


assembleMe : JsonApi.Document -> Result String Me
assembleMe document =
    JsonApi.Documents.primaryResource document
        :> \meResource ->
            JsonApi.Resources.attributes decodeMeAttributes meResource
                :> \name ->
                    Ok { name = name }


decodeMeAttributes : Decoder String
decodeMeAttributes =
    Decode.at [ "name" ] Decode.string


assembleProposal : JsonApi.Document -> Result String Proposal
assembleProposal document =
    JsonApi.Documents.primaryResource document
        :> assembleProposalFromResource


assembleProposalList : JsonApi.Document -> Result String ProposalList
assembleProposalList document =
    JsonApi.Documents.primaryResourceCollection document
        :> \proposalResourceList ->
            List.map
                assembleProposalFromResource
                proposalResourceList
                |> Result.Extra.combine


assembleProposalFromResource : JsonApi.Resource -> Result String Proposal
assembleProposalFromResource proposalResource =
    JsonApi.Resources.attributes decodeProposalAttributes proposalResource
        :> \proposalAttrs ->
            JsonApi.Resources.relatedResource "author" proposalResource
                :> \participantResource ->
                    JsonApi.Resources.attributes decodeParticipantAttributes participantResource
                        :> \name ->
                            Ok
                                { id = JsonApi.Resources.id proposalResource
                                , title = proposalAttrs.title
                                , body = proposalAttrs.body
                                , author =
                                    { id = JsonApi.Resources.id participantResource
                                    , name = name
                                    }
                                , supportCount = proposalAttrs.supportCount
                                , authoredByMe = proposalAttrs.authoredByMe
                                , supportedByMe = proposalAttrs.supportedByMe
                                }


type alias DecodedProposalAttributes =
    { title : String
    , body : String
    , supportCount : Int
    , authoredByMe : Bool
    , supportedByMe : Bool
    }


decodeProposalAttributes : Decoder DecodedProposalAttributes
decodeProposalAttributes =
    Decode.object5 DecodedProposalAttributes
        (Decode.at [ "title" ] Decode.string)
        (Decode.at [ "body" ] Decode.string)
        (Decode.at [ "support-count" ] Decode.int)
        (Decode.at [ "authored-by-me" ] Decode.bool)
        (Decode.at [ "supported-by-me" ] Decode.bool)


decodeParticipantAttributes : Decoder String
decodeParticipantAttributes =
    Decode.at [ "name" ] Decode.string


encodeProposalInput : NewProposal -> String
encodeProposalInput proposalInput =
    JsonApi.Extra.encodeDocument
        "proposal"
        Nothing
        [ ( "title", Encode.string proposalInput.title )
        , ( "body", Encode.string proposalInput.body )
        ]
        []


encodeSupportProposal : String -> String
encodeSupportProposal id =
    JsonApi.Extra.encodeDocument
        "support"
        Nothing
        []
        [ ( "proposal"
          , JsonApi.Extra.resourceLinkage <|
                Just ( "proposal", id )
          )
        ]


assembleSupport : JsonApi.Document -> Result String Support
assembleSupport document =
    JsonApi.Documents.primaryResource document
        :> \supportResource ->
            JsonApi.Resources.relatedResource "proposal" supportResource
                :> \proposalResource ->
                    JsonApi.Resources.attributes decodeProposalSupportAttributes proposalResource
                        :> \( supportCount, supportedByMe ) ->
                            Ok
                                { id = JsonApi.Resources.id supportResource
                                , proposal = JsonApi.Resources.id proposalResource
                                , supportCount = supportCount
                                , supportedByMe = supportedByMe
                                }


decodeProposalSupportAttributes : Decoder ( Int, Bool )
decodeProposalSupportAttributes =
    Decode.object2 (,)
        (Decode.at [ "support-count" ] Decode.int)
        (Decode.at [ "supported-by-me" ] Decode.bool)



-- COMMANDS


authenticate : String -> (Msg -> a) -> Cmd a
authenticate authCode wrapMsg =
    ("{\"auth_code\": \"" ++ authCode ++ "\"}")
        |> Api.Util.requestPost tokenEndpoint
        |> JsonApi.Extra.withHeader "Content-Type" "application/json"
        |> Api.Util.sendDefJson decodeToken
        |> Task.perform AuthFailed GotAccessToken
        |> Cmd.map wrapMsg


getMe : String -> (Msg -> a) -> Cmd a
getMe accessToken wrapMsg =
    meEndpoint
        |> Api.Util.requestGet
        |> Api.Util.withAccessToken accessToken
        |> Api.Util.sendDefJsonApi assembleMe
        |> Task.perform AuthFailed GotMe
        |> Cmd.map wrapMsg


createProposal : NewProposal -> String -> (Msg -> a) -> Cmd a
createProposal proposalInput accessToken wrapMsg =
    encodeProposalInput proposalInput
        |> Api.Util.requestPost newProposalEndpoint
        |> Api.Util.withAccessToken accessToken
        |> Api.Util.sendDefJsonApi assembleProposal
        |> Task.perform ProposalCreationFailed ProposalCreated
        |> Cmd.map wrapMsg


supportProposal : String -> Bool -> String -> (Msg -> a) -> Cmd a
supportProposal id newState accessToken wrapMsg =
    if newState then
        encodeSupportProposal id
            |> Api.Util.requestPost supportProposalEndpoint
            |> Api.Util.withAccessToken accessToken
            |> Api.Util.sendDefJsonApi assembleSupport
            |> Task.perform SupportProposalFailed ProposalSupported
            |> Cmd.map wrapMsg
    else
        unsupportProposalEndpoint id
            |> Api.Util.requestDelete
            |> Api.Util.withAccessToken accessToken
            |> Api.Util.sendDefDiscard
            |> Task.perform SupportProposalFailed (\_ -> ProposalUnsupported id)
            |> Cmd.map wrapMsg


getProposal : String -> String -> (Msg -> a) -> Cmd a
getProposal id accessToken wrapMsg =
    getProposalEndpoint id
        |> Api.Util.requestGet
        |> Api.Util.withAccessToken accessToken
        |> Api.Util.sendDefJsonApi assembleProposal
        |> Task.perform GettingProposalFailed GotProposal
        |> Cmd.map wrapMsg


getProposalList : String -> (Msg -> a) -> Cmd a
getProposalList accessToken wrapMsg =
    getProposalListEndpoint
        |> Api.Util.requestGet
        |> Api.Util.withAccessToken accessToken
        |> Api.Util.sendDefJsonApi assembleProposalList
        |> Task.perform GettingProposalListFailed GotProposalList
        |> Cmd.map wrapMsg
