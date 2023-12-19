%%
%% Copyright (c) 2017, 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Auxiliatry parsing functions
%%

-module(ersip_parser_aux).
-include("ersip_sip_abnf.hrl").

-export([quoted_string/1,
         unquoted_string/1,
         token_list/2,
         check_token/1,
         parse_all/2,
         parse_token/1,
         parse_lws/1,
         trim_lws/1,
         parse_slash/1,
         parse_sep/2,
         parse_non_neg_int/1,
         parse_pos_int/1,
         parse_kvps/3,
         parse_params/2,
         parse_gen_param_value/1
        ]).

-export_type([parse_result/0,
              parse_result/1,
              parse_result/2,
              parser_fun/0,
              separator/0,
              gen_param_list/0,
              parse_token_error/0]).

%%%===================================================================
%%% Types
%%%===================================================================

-type parse_result(T) :: parse_result(T, term()).
-type parse_result(T, Err) :: {ok, ParseResult :: T, Rest :: binary()}
                            | {error, Err}.
-type parse_result() :: parse_result(term()).

-type parser_fun()           :: fun((binary()) -> parse_result()).
-type separator()            :: lws.
-type parse_kvps_validator() ::
        fun((Key :: binary(),
             MayBeValue :: novalue | binary())
            -> {ok, {Key :: term(), Value :: term()}}
                   | {error, term()}
                   | skip).
-type gen_param()      :: {Key :: binary(), gen_param_value()}.
-type gen_param_list() :: [gen_param()].
-type gen_param_value() :: binary().

-type parse_token_error() :: {not_a_token, binary()}.

%%%===================================================================
%%% API
%%%===================================================================

%% @doc Parse quoted string (with unquoute).
%% DQUOTE *(qdtext / quoted-pair ) DQUOTE
%% qdtext         =  LWS / %x21 / %x23-5B / %x5D-7E
%%                        / UTF8-NONASCII
%% The backslash character ("\") MAY be used as a single-character
%% quoting mechanism only within quoted-string and comment constructs.
%% Unlike HTTP/1.1, the characters CR and LF cannot be escaped by this
%% mechanism to avoid conflict with line folding and header separation.
-spec quoted_string(Quoted) -> {ok, Quoted, Rest} | error when
      Quoted :: binary(),
      Quoted :: binary(),
      Rest   :: binary().
quoted_string(Quoted) ->
    Trimmed = ersip_bin:trim_head_lws(Quoted),
    TrimmedLen = byte_size(Trimmed),
    case ersip_quoted_string:skip(Trimmed) of
        {ok, Rest} ->
            Len = TrimmedLen - byte_size(Rest),
            {ok, binary:part(Trimmed, 0, Len), Rest};
        error ->
            error
    end.

-spec unquoted_string(binary()) -> parse_result(binary()).
unquoted_string(Quoted) ->
    ersip_quoted_string:unquoting_parse(Quoted).

%% @doc Parse token list separated with SEP
-spec token_list(binary(), SEP) -> {ok, [Token, ...], Rest} | error when
      SEP    :: separator(),
      Token  :: binary(),
      Rest   :: binary().
token_list(Binary, SEP) ->
    CompiledPattern = compile_pattern(SEP),
    token_list_impl(Binary, [], CompiledPattern).

%% @doc Check binary is token
%% token       =  1*(alphanum / "-" / "." / "!" / "%" / "*"
%%                   / "_" / "+" / "`" / "'" / "~" )
-spec check_token(binary()) -> boolean().
check_token(Bin) ->
    check_token(Bin, start).

%% @doc Apply series of parsers:
-spec parse_all(binary(), [ParserFun]) -> ParseAllResult when
      ParserFun      :: fun((binary()) -> parse_result()),
      ParseAllResult :: {ok, [ParseResult], Rest :: binary()}
                      | {error, term()},
      ParseResult    :: term().
parse_all(Binary, Parsers) ->
    parse_all_impl(Binary, Parsers, []).

%% @doc Parse SIP token
-spec parse_token(binary()) -> parse_result(binary(), parse_token_error()).
parse_token(Bin) ->
    End = find_token_end(Bin, 0),
    case End of
        0 -> {error, {not_a_token, Bin}};
        _ ->
            <<Result:End/binary, Rest/binary>> = Bin,
            {ok, Result, Rest}
    end.

-spec parse_lws(binary()) ->  parse_result({lws, pos_integer()}).
parse_lws(Bin) ->
    Trimmed = ersip_bin:trim_head_lws(Bin),
    case byte_size(Bin) - byte_size(Trimmed) of
        0 ->
            {error,  {lws_expected, Bin}};
        N ->
            {ok, {lws, N}, Trimmed}
    end.

%% SLASH   =  SWS "/" SWS ; slash
-spec parse_slash(binary()) -> ersip_parser_aux:parse_result().
parse_slash(Binary) ->
    SEPParser = fun(Bin) -> parse_sep($/, Bin) end,
    Parsers = [fun trim_lws/1,
               SEPParser,
               fun trim_lws/1
              ],
    case ersip_parser_aux:parse_all(Binary, Parsers) of
        {ok, [_, _, _], Rest} ->
            {ok, slash, Rest};
        {error, _} = Error ->
            Error
    end.


-spec trim_lws(binary()) ->  {ok, {lws, pos_integer()}, Rest :: binary()}.
trim_lws(Bin) ->
    Trimmed = ersip_bin:trim_head_lws(Bin),
    N = byte_size(Bin) - byte_size(Trimmed),
    {ok, {lws, N}, Trimmed}.

-spec parse_non_neg_int(binary()) -> parse_result(non_neg_integer(), {invalid_integer, binary()}).
parse_non_neg_int(Bin) ->
    parse_non_neg_int_impl(Bin, start, 0).

-spec parse_pos_int(binary()) -> parse_result(pos_integer(), {invalid_integer, binary()}).
parse_pos_int(Bin) ->
    parse_pos_int_impl(Bin, start, 0).

%% @doc Parse key-value pairs sepeated with Sep.
%% Validator may:
%% - transform key-value to another key/value pair
%% - skip key-value pair
%% - return error on pair
-spec parse_kvps(Validator, Sep, binary()) -> parse_result([{Key, Value} | Key]) when
      Key   :: any(),
      Value :: any(),
      Sep   :: binary(),
      Validator :: parse_kvps_validator().
parse_kvps(_, _, <<>>) ->
    {ok, [], <<>>};
parse_kvps(Validator, Sep, Bin) ->
    KVPs = binary:split(Bin, Sep, [global]),
    SplittedPairs =
        lists:map(fun(KVP) -> binary:split(KVP, <<"=">>) end,
                  KVPs),
    try
        ParseResult =
            lists:filtermap(parse_kvps_make_validator_func(Validator),
                            SplittedPairs),
        {ok, ParseResult, <<>>}
    catch
        throw:Error ->
            Error
    end.

%% generic-param 1*(Sep generic-param)
-spec parse_params(char(), binary()) -> parse_result(gen_param_list()).
parse_params(Sep, Bin) ->
    do_parse_params(ersip_bin:trim_head_lws(Bin), Sep, []).

%% generic-param  =  token [ EQUAL gen-value ]
-spec parse_gen_param(binary()) -> parse_result(gen_param()).
parse_gen_param(Bin) ->
    case parse_token(Bin) of
        {ok, Key, Rest0} ->
            Rest1 = ersip_bin:trim_head_lws(Rest0),
            case parse_sep($=, Rest1) of
                {ok, _, Rest2} ->
                    Rest3 = ersip_bin:trim_head_lws(Rest2),
                    case parse_gen_param_value(Rest3) of
                        {ok, Value, Rest4} ->
                            {ok, {Key, Value}, Rest4};
                        {error, Reason} ->
                            {error, {invalid_param_value, Reason}}
                    end;
                {error, _} ->
                    {ok, {Key, <<>>}, Rest0}
            end;
        {error, Reason} ->
            {error, {invalid_param, Reason}}
    end.

%% gen-value      =  token / host / quoted-string
-spec parse_gen_param_value(binary()) -> parse_result(gen_param_value()).
parse_gen_param_value(<<>>) ->
    {ok, <<>>, <<>>};
parse_gen_param_value(Bin) ->
    case quoted_string(Bin) of
        {ok, Val, Rest} ->
            {ok, Val, Rest};
        error ->
            case parse_gen_param_val_token(Bin) of
                {ok, _, _} = R ->
                    R;
                _ ->
                    case ersip_host:parse(Bin) of
                        {ok, _Host, Rest} ->
                            RestPos = byte_size(Bin) - byte_size(Rest),
                            <<HostBin:RestPos/binary, _/binary>> = Bin,
                            {ok, HostBin, Rest};
                        _ ->
                            {error, {inval_gen_param_value, Bin}}
                    end
            end
    end.

%%%===================================================================
%%% Internal implementation
%%%===================================================================

%% @private
-spec token_list_impl(binary(), [binary()], binary:cp()) -> Result when
      Result :: {ok, [Token, ...], Rest}
              | error,
      Token  :: binary(),
      Rest   :: binary().
token_list_impl(Binary, Acc, CompPattern) ->
    case binary:split(Binary, CompPattern) of
        [<<>>, Rest] ->
            token_list_impl(Rest, Acc, CompPattern);
        [T, Rest] ->
            case check_token(T) of
                true ->
                    token_list_impl(Rest, [T | Acc], CompPattern);
                false ->
                    token_list_impl_process_rest(Acc, Binary)
            end;
        [T] ->
            case check_token(T) of
                true ->
                    {ok, lists:reverse([T | Acc]), <<>>};
                false ->
                    token_list_impl_process_rest(Acc, Binary)
            end
    end.

-spec token_list_impl_process_rest([Token], binary()) -> Result when
      Result :: {ok, [Token, ...], Rest}
              | error,
      Token :: binary(),
      Rest  :: binary().
token_list_impl_process_rest(Acc, Binary) ->
    {Acc1, Rest1} =
        case find_token_end(Binary, 0) of
            0 ->
                {Acc, Binary};
            N ->
                <<LastToken:N/binary, Rest0/binary>> = Binary,
                {[LastToken|Acc], Rest0}
        end,
    case Acc1 of
        [] ->
            error;
        _ ->
            {ok, lists:reverse(Acc1), Rest1}
    end.


%% @private
-spec check_token(binary(), start | rest) -> boolean().
check_token(<<>>, start) ->
    false;
check_token(<<>>, rest) ->
    true;
check_token(<<Char/utf8, R/binary>>, _) when ?is_token_char(Char) ->
    check_token(R, rest);
check_token(_, _) ->
    false.

-spec find_token_end(binary(), non_neg_integer()) -> non_neg_integer().
find_token_end(<<Char/utf8, R/binary>>, Pos) when ?is_token_char(Char) ->
    find_token_end(R, Pos+byte_size(<<Char/utf8>>));
find_token_end(_, Pos) ->
    Pos.

%% @private
-spec compile_pattern(separator()) -> binary:cp().
compile_pattern(lws) ->
    binary:compile_pattern([<<" ">>, <<"\t">>]).

-spec parse_all_impl(binary(), [ParserFun], Acc) -> ParseAllResult when
      ParserFun      :: fun((binary()) -> parse_result()),
      ParseAllResult :: {ok, [ParseResult], Rest :: binary()}
                      | {error, term()},
      ParseResult    :: term(),
      Acc            :: list().
parse_all_impl(Binary, [], Acc) ->
    {ok, lists:reverse(Acc), Binary};
parse_all_impl(Binary, [F | FRest], Acc) ->
    case F(Binary) of
        {ok, ParseResult, BinRest} ->
            parse_all_impl(BinRest, FRest, [ParseResult | Acc]);
        {error, Error} ->
            {error, Error}
    end.

-spec parse_non_neg_int_impl(binary(), State , Acc) -> parse_result(non_neg_integer()) when
      State :: start | rest,
      Acc :: non_neg_integer().
parse_non_neg_int_impl(<<Char/utf8, _/binary>> = Bin, start, Acc) when Char >= $0 andalso Char =< $9 ->
    parse_non_neg_int_impl(Bin, rest, Acc);
parse_non_neg_int_impl(Bin, start, _) ->
    {error, {invalid_integer, Bin}};
parse_non_neg_int_impl(<<Char/utf8, R/binary>>, rest, Acc) when Char >= $0 andalso Char =< $9 ->
    parse_non_neg_int_impl(R, rest, Acc * 10 + Char - $0);
parse_non_neg_int_impl(Rest, rest, Acc) ->
    {ok, Acc, Rest}.

-spec parse_pos_int_impl(binary(), State, Acc) -> parse_result(pos_integer()) when
      State :: start | rest,
      Acc :: non_neg_integer().
parse_pos_int_impl(<<Char/utf8, _/binary>> = Bin, start, Acc) when Char >= $1 andalso Char =< $9 ->
    parse_pos_int_impl(Bin, rest, Acc);
parse_pos_int_impl(Bin, start, _) ->
    {error, {invalid_integer, Bin}};
parse_pos_int_impl(<<Char/utf8, R/binary>>, rest, Acc) when Char >= $0 andalso Char =< $9 ->
    parse_pos_int_impl(R, rest, Acc * 10 + Char - $0);
parse_pos_int_impl(Rest, rest, Acc) ->
    {ok, Acc, Rest}.

-spec parse_kvps_make_validator_func(parse_kvps_validator()) -> KVPsMapFun when
      KVPsMapFun :: fun((list()) -> {term(), term()}).
parse_kvps_make_validator_func(Validator) ->
    fun([Key, Value]) ->
            TKey = ersip_bin:trim_lws(Key),
            TVal = ersip_bin:trim_lws(Value),
            case Validator(TKey, TVal) of
                {ok, {K, V}} ->
                    {true, {K, V}};
                skip ->
                    false;
                {error, _} = Error ->
                    throw(Error)
            end;
       ([Key]) ->
            TKey = ersip_bin:trim_lws(Key),
            case Validator(TKey, novalue) of
                {ok, {K, V}} ->
                    {true, {K, V}};
                skip ->
                    false;
                {error, _} = Error ->
                    throw(Error)
            end
    end.

-spec parse_sep(char(), binary()) -> parse_result(char()).
parse_sep(Sep, <<Sep/utf8, R/binary>>) ->
    {ok, Sep, R};
parse_sep(Sep, Bin) ->
    {error, {no_separator, Sep, Bin}}.

-spec do_parse_params(binary(), char(), gen_param_list()) -> parse_result(gen_param_list()).
do_parse_params(Bin, Sep, Acc) ->
    case parse_gen_param(Bin) of
        {ok, Val, Rest0} ->
            Rest1 = ersip_bin:trim_lws(Rest0),
            case parse_sep(Sep, Rest1) of
                {ok, _, Rest2} ->
                    do_parse_params(ersip_bin:trim_lws(Rest2), Sep, [Val | Acc]);
                {error, _} ->
                    {ok, lists:reverse([Val | Acc]), Rest0}
            end;
        {error, _} = Error ->
            Error
    end.

%% @doc This is dirty hack to match dirty RFC3261 bug:
%% via-received      =  "received" EQUAL (IPv4address / IPv6address)
%%
%% IPv6address is not match generic parameter value, but if we add ":"
%% to token chars than it will.
-spec parse_gen_param_val_token(binary()) -> parse_result(binary(), {not_a_token, binary()}).
parse_gen_param_val_token(Bin) ->
    End = find_gen_param_val_token_end(Bin, 0),
    case End of
        0 -> {error, {not_a_token, Bin}};
        _ ->
            <<Result:End/binary, Rest/binary>> = Bin,
            {ok, Result, Rest}
    end.

-spec find_gen_param_val_token_end(binary(), non_neg_integer()) -> non_neg_integer().
find_gen_param_val_token_end(<<Char/utf8, R/binary>>, Pos) when ?is_token_char(Char) orelse Char == $: ->
    find_gen_param_val_token_end(R, Pos+byte_size(<<Char/utf8>>));
find_gen_param_val_token_end(_, Pos) ->
    Pos.
