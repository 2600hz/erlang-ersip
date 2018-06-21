%%
%% Copyright (c) 2018 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% SIP One SIP Contact entry
%%

-module(ersip_hdr_contact).

-export([make/1,
         parse/1,
         assemble/1
        ]).
-export_type([contact/0]).

%%%===================================================================
%%% Types
%%%===================================================================

-record(contact, {display_name  :: undefined | ersip_nameaddr:display_name(),
                  uri           :: ersip_uri:uri(),
                  params        :: [contact_param()]
                 }).
-type contact() :: #contact{}.

-type contact_param() :: {qvalue, ersip_qvalue:qvalue()}
                       | {expires, expires()}
                       | {binary(), binary()}.
-type expires() :: non_neg_integer().

-type parse_result() :: {ok, contact}
                      | {error, term()}.

%%%===================================================================
%%% API
%%%===================================================================

-spec make(binary()) -> contact().
make(Bin) ->
    case ersip_hdr_contact:parse(Bin) of
        {ok, Contact} ->
            Contact;
        {error, Reason} ->
            error(Reason)
    end.

-spec parse(binary()) -> parse_result().
parse(Bin) ->
    Parsers = [fun ersip_nameaddr:parse/1,
               fun ersip_parser_aux:trim_lws/1,
               fun parse_contact_params/1
              ],
    case ersip_parser_aux:parse_all(Bin, Parsers) of
        {ok, [{DisplayName, URI}, _, ParamsList], <<>>} ->
            {ok,
             #contact{display_name = DisplayName,
                      uri          = URI,
                      params       = ParamsList
                     }
            };
        {error, Reason} ->
            {error, {invalid_contact, Reason}}
    end.

-spec assemble(contact()) -> iolist().
assemble(#contact{} = Contact) ->
    #contact{display_name = DN,
           uri = URI,
           params = ParamsList
          } = Contact,
    [ersip_nameaddr:assemble(DN, URI),
     lists:map(fun({q, QValue}) ->
                       [<<";q=">>, ersip_qvalue:assemble(QValue)];
                  ({expires, Expires}) ->
                       ExpiresBin = integer_to_binary(Expires),
                       [<<";expires=", ExpiresBin/binary>>];
                  ({Key, Value}) when is_binary(Value) ->
                       [<<";">>, Key, <<"=">>, Value];
                  ({Key, novalue})  ->
                       [<<";">>, Key]
               end,
               ParamsList)
    ].

%%%===================================================================
%%% Internal Implementation
%%%===================================================================

-spec parse_contact_params(binary()) -> ersip_parser_aux:parse_result([contact_param()]).
parse_contact_params(<<$;, Bin/binary>>) ->
    parse_contact_params(Bin);
parse_contact_params(<<>>) ->
    {ok, [], <<>>};
parse_contact_params(Bin) ->
    ersip_parser_aux:parse_kvps(fun contact_params_validator/2,
                                <<";">>,
                                Bin).

-spec contact_params_validator(binary(), binary() | novalue) -> Result when
      Result :: {ok, {binary(), novalue}}
              | {ok, {binary(), binary()}}
              | {error, {invalid_rr_param, binary()}}.
contact_params_validator(<<"q">>, Value) ->
    case ersip_qvalue:parse(Value) of
        {ok, QValue} ->
            {ok, {q, QValue}};
        {error, Reason} ->
            {error, {invalid_contact, Reason}}
    end;
contact_params_validator(<<"expires">>, Value) ->
    try
        {ok, {expires, binary_to_integer(Value)}}
    catch
        error:badarg ->
            {error, {invalid_contact, {invalid_expires, Value}}}
    end;
contact_params_validator(Key, novalue) ->
    case ersip_parser_aux:check_token(Key) of
        true ->
            {ok, {Key, novalue}};
        false ->
            {error, {invalid_contact, {invalid_param, Key}}}
    end;
contact_params_validator(Key, Value) when is_binary(Value) ->
    case ersip_parser_aux:check_token(Key) of
        true ->
            {ok, {Key, Value}};
        false ->
            {error, {invalid_contact, {invalid_param, Key}}}
    end.