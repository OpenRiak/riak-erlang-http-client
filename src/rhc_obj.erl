%% -------------------------------------------------------------------
%%
%% riakhttpc: Riak HTTP Client
%%
%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------

%% @doc This module contains utilities that the rhc module uses for
%%      translating between HTTP (ibrowse) data and riakc_obj objects.
-module(rhc_obj).

-export([make_riakc_obj/4, serialize_riakc_obj/2, ctype_from_headers/1]).

-include("raw_http.hrl").
-include("rhc.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%% HTTP -> riakc_obj

make_riakc_obj(Bucket, Key, Headers, Body) ->
    HeaderMap = make_rspheader_map(Headers),
    Vclock = maps:get(?LOWER_VCLOCK, HeaderMap, ""),
    case maps:get(?LOWER_CTYPE, HeaderMap) of
        {"multipart/mixed", Args} ->
            {"boundary", Boundary} = proplists:lookup("boundary", Args),
            riakc_obj:new_obj(
                Bucket,
                Key,
                Vclock,
                decode_siblings(Boundary, Body)
            );
        {_CType, _} ->
            riakc_obj:new_obj(
                Bucket,
                Key,
                Vclock,
                [{headers_to_metadata(HeaderMap), Body}]
            )
    end.

ctype_from_headers(Headers) ->
    mochiweb_util:parse_header(
      proplists:get_value(?HEAD_CTYPE, Headers)).

decode_siblings(Boundary, <<"\r\n",SibBody/binary>>) ->
    decode_siblings(Boundary, SibBody);
decode_siblings(Boundary, SibBody) ->
    lists:map(
        fun({_, {_, Headers}, Body}) ->
            HeaderMap = make_rspheader_map(Headers),
            {
                headers_to_metadata(HeaderMap),
                element(1, split_binary(Body, size(Body)))
            }
        end,
        webmachine_multipart:get_all_parts(SibBody, Boundary)
    ).

make_rspheader_map(Headers) ->
    lists:foldl(
        fun({HeadKey, HeadVal}, AccMap) ->
            BinHeadKey =
                case HeadKey of
                    HeadKey when is_binary(HeadKey) ->
                        HeadKey;
                    HeadKey when is_list(HeadKey) ->
                        list_to_binary(HeadKey)
                end,
            ListHeadVal =
                case HeadVal of
                    HeadVal when is_binary(HeadVal) ->
                        binary_to_list(HeadVal);
                    HeadVal when is_list(HeadVal) ->
                        HeadVal
                end,
            accumulate_header_info(
                string:lowercase(BinHeadKey),
                BinHeadKey,
                ListHeadVal,
                AccMap
            )
        end,
        maps:new(),
        Headers
    ).

accumulate_header_info(<<?LOWER_INDEX_PREFIX, _Field/binary>>, OriginalKey, T, MapAcc) ->
    <<_Prefix:13/binary, Field/binary>> = OriginalKey,
    maps:update_with(
        <<?LOWER_INDEX_PREFIX>>,
        fun(Indices) -> [{Field, T}|Indices] end,
        [{Field, T}],
        MapAcc
    );
accumulate_header_info(<<?LOWER_USERMETA_PREFIX, _MetaKey/binary>>, OriginalKey, V, MapAcc) ->
    <<_Prefix:12/binary, MetaKey/binary>> = OriginalKey,
    maps:update_with(
        <<?LOWER_USERMETA_PREFIX>>,
        fun(Indices) -> [{MetaKey, V}|Indices] end,
        [{MetaKey, V}],
        MapAcc
    );
accumulate_header_info(?LOWER_CTYPE, _OK, V, MapAcc) ->
    maps:put(?LOWER_CTYPE, mochiweb_util:parse_header(V), MapAcc);
accumulate_header_info(?LOWER_VTAG, _OK, V, MapAcc) ->
    maps:put(?LOWER_VTAG, V, MapAcc);
accumulate_header_info(?LOWER_VCLOCK, _OK, VC, MapAcc) ->
    maps:put(?LOWER_VCLOCK, base64:decode(VC), MapAcc);
accumulate_header_info(?LOWER_LINK, _OK, V, MapAcc) ->
    maps:put(?LOWER_LINK, V, MapAcc);
accumulate_header_info(?LOWER_LMD, _OK, V, MapAcc) ->
    maps:put(?LOWER_LMD, V, MapAcc);
accumulate_header_info(_DiscardIdx, _OK, _Value, MapAcc) ->
    MapAcc.

headers_to_metadata(HeaderMap) ->
    UserMetaKVL = maps:get(<<?LOWER_USERMETA_PREFIX>>, HeaderMap, []),
    UserMeta = 
        lists:foldl(
            fun({K, V}, Acc) ->
                VBin =
                    case V of
                        VL when is_list(VL) ->
                            list_to_binary(VL);
                        VB when is_binary(VB) ->
                            VB
                    end,
                riakc_obj:set_user_metadata_entry(Acc, {K, VBin})
            end,
            dict:new(),
            UserMetaKVL
        ),
    

    {CType,_} = maps:get(?LOWER_CTYPE, HeaderMap),
    CUserMeta = dict:store(?MD_CTYPE, CType, UserMeta),

    VTag = maps:get(?LOWER_VTAG, HeaderMap),
    VCUserMeta = dict:store(?MD_VTAG, VTag, CUserMeta),

    LVCUserMeta =
        case maps:get(?LOWER_LMD, HeaderMap, undefined) of
            undefined ->
                VCUserMeta;
            RfcDate ->
                GS =
                    calendar:datetime_to_gregorian_seconds(
                        httpd_util:convert_request_date(RfcDate)
                    ),
                ES = GS-62167219200, %% gregorian seconds of the epoch
                dict:store(
                    ?MD_LASTMOD,
                    {ES div 1000000, ES rem 1000000, 0},
                    VCUserMeta
                )
        end,

    LinkMeta = case extract_links(HeaderMap) of
        [] -> LVCUserMeta;
        Links -> dict:store(?MD_LINKS, Links, LVCUserMeta)
    end,
    case extract_indexes(HeaderMap) of
        [] -> LinkMeta;
        Entries -> dict:store(?MD_INDEX, Entries, LinkMeta)
    end.


extract_links(HeaderMap) ->
    {ok, Re} = re:compile("</[^/]+/([^/]+)/([^/]+)>; *riaktag=\"(.*)\""),
    Extractor =
        fun(L, Acc) ->
                case re:run(L, Re, [{capture,[1,2,3],binary}]) of
                    {match, [Bucket, Key,Tag]} ->
                        [{{Bucket,Key},Tag}|Acc];
                    nomatch ->
                        Acc
                end
        end,
    LinkHeader = maps:get(?HEAD_LINK, HeaderMap, []),
    lists:foldl(Extractor, [], string:lexemes(LinkHeader, ",")).

extract_indexes(HeaderMap) ->
    lists:flatten(
        lists:map(
            fun({F, V}) ->
                decode_index_value(F, V)
            end,
            maps:get(<<?LOWER_INDEX_PREFIX>>, HeaderMap, [])
        )
    ).

decode_index_value(K, V) ->
    TL = lists:reverse(string:split(V, ", ", all)),
    case lists:last(string:lexemes(K, "_")) of
        <<"bin">> ->
            lists:map(fun(T) -> {K, list_to_binary(T)} end, TL);
        <<"int">> ->
            lists:map(fun(T) -> {K, list_to_integer(T)} end, TL)
    end.

serialize_riakc_obj(Rhc, Object) ->
    {make_headers(Rhc, Object), make_body(Object)}.

make_headers(Rhc, Object) ->
    MD = riakc_obj:get_update_metadata(Object),
    CType = case dict:find(?MD_CTYPE, MD) of
                {ok, C} when is_list(C) -> C;
                {ok, C} when is_binary(C) -> binary_to_list(C);
                error -> "application/octet-stream"
            end,
    Links = case dict:find(?MD_LINKS, MD) of
                {ok, L} -> L;
                error   -> []
            end,
    VClock = riakc_obj:vclock(Object),
    lists:flatten(
      [{?HEAD_CTYPE, CType},
       [ {?HEAD_LINK, encode_links(Rhc, Links)} || Links =/= [] ],
       [ {?HEAD_VCLOCK, base64:encode_to_string(VClock)}
         || VClock =/= undefined ],
       encode_indexes(MD)
       | encode_user_metadata(MD) ]).

encode_links(_, []) -> [];
encode_links(#rhc{prefix=Prefix}, Links) ->
    {{FirstBucket, FirstKey}, FirstTag} = hd(Links),
    lists:foldl(
      fun({{Bucket, Key}, Tag}, Acc) ->
              [format_link(Prefix, Bucket, Key, Tag), ", "|Acc]
      end,
      format_link(Prefix, FirstBucket, FirstKey, FirstTag),
      tl(Links)).

encode_user_metadata(_Metadata) ->
    %% TODO
    [].

encode_indexes(MD) ->
    case dict:find(?MD_INDEX, MD) of
        {ok, Entries} ->
            [ encode_index(Pair) || {_,_}=Pair <- Entries];
        error ->
            []
    end.

encode_index({Name, IntValue}) when is_integer(IntValue) ->
    encode_index({Name, integer_to_list(IntValue)});
encode_index({Name, BinValue}) when is_binary(BinValue) ->
    encode_index({Name, unicode:characters_to_list(BinValue, latin1)});
encode_index({Name, String}) when is_list(String) ->
    {?HEAD_INDEX_PREFIX ++ unicode:characters_to_list(Name, latin1),
     String}.

format_link(_Prefix, Bucket, Key, Tag) ->
    io_lib:format("</buckets/~s/keys/~s>; riaktag=\"~s\"",
                  [Bucket, Key, Tag]).

make_body(Object) ->
    case riakc_obj:get_update_value(Object) of
        Val when is_binary(Val) -> 
            Val
    end.

-ifdef(TEST).

headers_test() ->
    HeaderList =
        [
            {"x-riak-index-field1_bin", "I0001, I0002"},
            {"x-riak-index-field2_int", "1, 2"},
            {"X-Riak-Index-field3_bin", "I0003"},
            {"x-riak-meta-K0001", "V0001"},
            {"x-riak-meta-K0002", "V0002"},
            {"ETag", "abc123"},
            {"content-type", "application/json"}
        ],
    HeaderMap = make_rspheader_map(HeaderList),
    Metadata = headers_to_metadata(HeaderMap),
    ExpectedMetadata =
        dict:from_list(
            [
                {
                    <<"X-Riak-Meta">>,
                    [
                        {<<"K0001">>,<<"V0001">>},
                        {<<"K0002">>,<<"V0002">>}
                    ]
                },
                {
                    <<"index">>,
                    [
                        {<<"field3_bin">>,<<"I0003">>},
                        {<<"field2_int">>, 2},
                        {<<"field2_int">>, 1},
                        {<<"field1_bin">>,<<"I0002">>},
                        {<<"field1_bin">>,<<"I0001">>}
                    ]
                },
                {
                    <<"content-type">>,
                    "application/json"
                },
                {
                    <<"X-Riak-VTag">>,
                    "abc123"
                }
            ]
        ),
    ?assertMatch(
        ExpectedMetadata,
        Metadata
    ).


-endif.
