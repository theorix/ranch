%% Copyright (c) 2011-2018, Loïc Hoguin <essen@ninenines.eu>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

-module(ranch).

-export([start_listener/5]).
-export([start_listener/6]).
-export([stop_listener/1]).
-export([suspend_listener/1]).
-export([resume_listener/1]).
-export([child_spec/5]).
-export([child_spec/6]).
-export([accept_ack/1]).
-export([remove_connection/1]).
-export([get_status/1]).
-export([get_addr/1]).
-export([get_port/1]).
-export([get_max_connections/1]).
-export([set_max_connections/2]).
-export([get_transport_options/1]).
-export([set_transport_options/2]).
-export([get_protocol_options/1]).
-export([set_protocol_options/2]).
-export([info/0]).
-export([info/1]).
-export([procs/2]).
-export([wait_for_connections/3]).
-export([wait_for_connections/4]).
-export([filter_options/3]).
-export([set_option_default/3]).
-export([require/1]).

-deprecated([start_listener/6, child_spec/6]).

-type max_conns() :: non_neg_integer() | infinity.
-export_type([max_conns/0]).

-type opt() :: {ack_timeout, timeout()}
	| {connection_type, worker | supervisor}
	| {max_connections, max_conns()}
	| {num_acceptors, pos_integer()}
	| {shutdown, timeout() | brutal_kill}
	| {socket, any()}.
-export_type([opt/0]).

-type ref() :: any().
-export_type([ref/0]).

-spec start_listener(ref(), module(), any(), module(), any())
	-> supervisor:startchild_ret().
start_listener(Ref, Transport, TransOpts, Protocol, ProtoOpts) ->
	NumAcceptors = proplists:get_value(num_acceptors, TransOpts, 10),
	start_listener(Ref, NumAcceptors, Transport, TransOpts, Protocol, ProtoOpts).

-spec start_listener(ref(), non_neg_integer(), module(), any(), module(), any())
	-> supervisor:startchild_ret().
start_listener(Ref, NumAcceptors, Transport, TransOpts, Protocol, ProtoOpts)
		when is_integer(NumAcceptors) andalso is_atom(Transport)
		andalso is_atom(Protocol) ->
	_ = code:ensure_loaded(Transport),
	case erlang:function_exported(Transport, name, 0) of
		false ->
			{error, badarg};
		true ->
			Res = supervisor:start_child(ranch_sup, child_spec(Ref, NumAcceptors,
					Transport, TransOpts, Protocol, ProtoOpts)),
			Socket = proplists:get_value(socket, TransOpts),
			case Res of
				{ok, Pid} when Socket =/= undefined ->
					%% Give ownership of the socket to ranch_acceptors_sup
					%% to make sure the socket stays open as long as the
					%% listener is alive. If the socket closes however there
					%% will be no way to recover because we don't know how
					%% to open it again.
					Children = supervisor:which_children(Pid),
					{_, AcceptorsSup, _, _}
						= lists:keyfind(ranch_acceptors_sup, 1, Children),
					%%% Note: the catch is here because SSL crashes when you change
					%%% the controlling process of a listen socket because of a bug.
					%%% The bug will be fixed in R16.
					catch Transport:controlling_process(Socket, AcceptorsSup);
				_ ->
					ok
			end,
			maybe_started(Res)
	end.

maybe_started({error, {{shutdown,
		{failed_to_start_child, ranch_acceptors_sup,
			{listen_error, _, Reason}}}, _}} = Error) ->
	start_error(Reason, Error);
maybe_started(Res) ->
	Res.

start_error(E=eaddrinuse, _) -> {error, E};
start_error(E=eacces, _) -> {error, E};
start_error(E=no_cert, _) -> {error, E};
start_error(_, Error) -> Error.

-spec stop_listener(ref()) -> ok | {error, not_found}.
stop_listener(Ref) ->
	case supervisor:terminate_child(ranch_sup, {ranch_listener_sup, Ref}) of
		ok ->
			_ = supervisor:delete_child(ranch_sup, {ranch_listener_sup, Ref}),
			ranch_server:cleanup_listener_opts(Ref);
		{error, Reason} ->
			{error, Reason}
	end.

-spec suspend_listener(ref()) -> ok | {error, term()}.
suspend_listener(Ref) ->
	case get_status(Ref) of
		running ->
			ListenerSup = ranch_server:get_listener_sup(Ref),
			ok = ranch_server:set_addr(Ref, {undefined, undefined}),
			supervisor:terminate_child(ListenerSup, ranch_acceptors_sup);
		suspended ->
			ok
	end.

-spec resume_listener(ref()) -> ok | {error, term()}.
resume_listener(Ref) ->
	case get_status(Ref) of
		running ->
			ok;
		suspended ->
			ListenerSup = ranch_server:get_listener_sup(Ref),
			Res = supervisor:restart_child(ListenerSup, ranch_acceptors_sup),
			maybe_resumed(Res)
	end.

maybe_resumed(Error={error, {listen_error, _, Reason}}) ->
	start_error(Reason, Error);
maybe_resumed({ok, _}) ->
	ok;
maybe_resumed({ok, _, _}) ->
	ok;
maybe_resumed(Res) ->
	Res.

-spec child_spec(ref(), module(), any(), module(), any())
	-> supervisor:child_spec().
child_spec(Ref, Transport, TransOpts, Protocol, ProtoOpts) ->
	NumAcceptors = proplists:get_value(num_acceptors, TransOpts, 10),
	child_spec(Ref, NumAcceptors, Transport, TransOpts, Protocol, ProtoOpts).

-spec child_spec(ref(), non_neg_integer(), module(), any(), module(), any())
	-> supervisor:child_spec().
child_spec(Ref, NumAcceptors, Transport, TransOpts, Protocol, ProtoOpts)
		when is_integer(NumAcceptors) andalso is_atom(Transport)
		andalso is_atom(Protocol) ->
	{{ranch_listener_sup, Ref}, {ranch_listener_sup, start_link, [
		Ref, NumAcceptors, Transport, TransOpts, Protocol, ProtoOpts
	]}, permanent, infinity, supervisor, [ranch_listener_sup]}.

-spec accept_ack(ref()) -> ok.
accept_ack(Ref) ->
	receive {shoot, Ref, Transport, Socket, AckTimeout} ->
		Transport:accept_ack(Socket, AckTimeout)
	end.

-spec remove_connection(ref()) -> ok.
remove_connection(Ref) ->
	ConnsSup = ranch_server:get_connections_sup(Ref),
	ConnsSup ! {remove_connection, Ref, self()},
	ok.

-spec get_status(ref()) -> running | suspended | restarting.
get_status(Ref) ->
	ListenerSup = ranch_server:get_listener_sup(Ref),
	Children = supervisor:which_children(ListenerSup),
	case lists:keyfind(ranch_acceptors_sup, 1, Children) of
		{_, undefined, _, _} ->
			suspended;
		{_, AcceptorsSup, _, _} when is_pid(AcceptorsSup) ->
			running
	end.

-spec get_addr(ref()) -> {inet:ip_address(), inet:port_number()} | {undefined, undefined}.
get_addr(Ref) ->
	ranch_server:get_addr(Ref).

-spec get_port(ref()) -> inet:port_number() | undefined.
get_port(Ref) ->
	{_, Port} = get_addr(Ref),
	Port.

-spec get_max_connections(ref()) -> max_conns().
get_max_connections(Ref) ->
	ranch_server:get_max_connections(Ref).

-spec set_max_connections(ref(), max_conns()) -> ok.
set_max_connections(Ref, MaxConnections) ->
	ranch_server:set_max_connections(Ref, MaxConnections).

-spec get_transport_options(ref()) -> any().
get_transport_options(Ref) ->
	ranch_server:get_transport_options(Ref).

-spec set_transport_options(ref(), any()) -> ok | {error, running}.
set_transport_options(Ref, TransOpts) ->
	case get_status(Ref) of
		suspended ->
			ok = ranch_server:set_transport_options(Ref, TransOpts);
		running ->
			{error, running}
	end.

-spec get_protocol_options(ref()) -> any().
get_protocol_options(Ref) ->
	ranch_server:get_protocol_options(Ref).

-spec set_protocol_options(ref(), any()) -> ok.
set_protocol_options(Ref, Opts) ->
	ranch_server:set_protocol_options(Ref, Opts).

-spec info() -> [{any(), [{atom(), any()}]}].
info() ->
	[{Ref, listener_info(Ref, Pid)}
		|| {Ref, Pid} <- ranch_server:get_listener_sups()].

-spec info(ref()) -> [{atom(), any()}].
info(Ref) ->
	Pid = ranch_server:get_listener_sup(Ref),
	listener_info(Ref, Pid).

listener_info(Ref, Pid) ->
	[_, NumAcceptors, Transport, _, Protocol, _] = ranch_server:get_listener_start_args(Ref),
	ConnsSup = ranch_server:get_connections_sup(Ref),
	Status = get_status(Ref),
	{IP, Port} = get_addr(Ref),
	MaxConns = get_max_connections(Ref),
	TransOpts = ranch_server:get_transport_options(Ref),
	ProtoOpts = get_protocol_options(Ref),
	[
		{pid, Pid},
		{status, Status},
		{ip, IP},
		{port, Port},
		{num_acceptors, NumAcceptors},
		{max_connections, MaxConns},
		{active_connections, ranch_conns_sup:active_connections(ConnsSup)},
		{all_connections, proplists:get_value(active, supervisor:count_children(ConnsSup))},
		{transport, Transport},
		{transport_options, TransOpts},
		{protocol, Protocol},
		{protocol_options, ProtoOpts}
	].

-spec procs(ref(), acceptors | connections) -> [pid()].
procs(Ref, acceptors) ->
	procs1(Ref, ranch_acceptors_sup);
procs(Ref, connections) ->
	procs1(Ref, ranch_conns_sup).

procs1(Ref, Sup) ->
	ListenerSup = ranch_server:get_listener_sup(Ref),
	{_, SupPid, _, _} = lists:keyfind(Sup, 1,
		supervisor:which_children(ListenerSup)),
	try
		[Pid || {_, Pid, _, _} <- supervisor:which_children(SupPid)]
	catch exit:{noproc, _} when Sup =:= ranch_acceptors_sup ->
		[]
	end.

-spec wait_for_connections
	(ref(), '>' | '>=' | '==' | '=<', non_neg_integer()) -> ok;
	(ref(), '<', pos_integer()) -> ok.
wait_for_connections(Ref, Op, NumConns) ->
	wait_for_connections(Ref, Op, NumConns, 1000).

-spec wait_for_connections
	(ref(), '>' | '>=' | '==' | '=<', non_neg_integer(), non_neg_integer()) -> ok;
	(ref(), '<', pos_integer(), non_neg_integer()) -> ok.
wait_for_connections(Ref, Op, NumConns, Interval) ->
	validate_op(Op, NumConns),
	validate_num_conns(NumConns),
	validate_interval(Interval),
	wait_for_connections_loop(Ref, Op, NumConns, Interval).

validate_op('>', _) -> ok;
validate_op('>=', _) -> ok;
validate_op('==', _) -> ok;
validate_op('=<', _) -> ok;
validate_op('<', NumConns) when NumConns > 0 -> ok;
validate_op(_, _) -> error(badarg).

validate_num_conns(NumConns) when is_integer(NumConns), NumConns >= 0 -> ok;
validate_num_conns(_) -> error(badarg).

validate_interval(Interval) when is_integer(Interval), Interval >= 0 -> ok;
validate_interval(_) -> error(badarg).

wait_for_connections_loop(Ref, Op, NumConns, Interval) ->
	CurConns = try
		ConnsSup = ranch_server:get_connections_sup(Ref),
		proplists:get_value(active, supervisor:count_children(ConnsSup))
	catch _:_ ->
		0
	end,
	case erlang:Op(CurConns, NumConns) of
		true ->
			ok;
		false when Interval > 0 ->
			wait_for_connections_loop(Ref, Op, NumConns, Interval);
		false ->
			timer:sleep(Interval),
			wait_for_connections_loop(Ref, Op, NumConns, Interval)
	end.

-spec filter_options([inet | inet6 | {atom(), any()} | {raw, any(), any(), any()}],
	[atom()], Acc) -> Acc when Acc :: [any()].
filter_options(UserOptions, DisallowedKeys, DefaultOptions) ->
	AllowedOptions = filter_user_options(UserOptions, DisallowedKeys),
	lists:foldl(fun merge_options/2, DefaultOptions, AllowedOptions).

%% 2-tuple options.
filter_user_options([Opt = {Key, _}|Tail], DisallowedKeys) ->
	case lists:member(Key, DisallowedKeys) of
		false ->
			[Opt|filter_user_options(Tail, DisallowedKeys)];
		true ->
			filter_options_warning(Opt),
			filter_user_options(Tail, DisallowedKeys)
	end;
%% Special option forms.
filter_user_options([inet|Tail], AllowedKeys) ->
	[inet|filter_user_options(Tail, AllowedKeys)];
filter_user_options([inet6|Tail], AllowedKeys) ->
	[inet6|filter_user_options(Tail, AllowedKeys)];
filter_user_options([Opt = {raw, _, _, _}|Tail], AllowedKeys) ->
	[Opt|filter_user_options(Tail, AllowedKeys)];
filter_user_options([Opt|Tail], DisallowedKeys) ->
	filter_options_warning(Opt),
	filter_user_options(Tail, DisallowedKeys);
filter_user_options([], _) ->
	[].

filter_options_warning(Opt) ->
	error_logger:warning_msg("Transport option ~p unknown or invalid.~n", [Opt]).

merge_options({Key, _} = Option, OptionList) ->
	lists:keystore(Key, 1, OptionList, Option);
merge_options(Option, OptionList) ->
	[Option|OptionList].

-spec set_option_default(Opts, atom(), any())
	-> Opts when Opts :: [{atom(), any()}].
set_option_default(Opts, Key, Value) ->
	case lists:keymember(Key, 1, Opts) of
		true -> Opts;
		false -> [{Key, Value}|Opts]
	end.

-spec require([atom()]) -> ok.
require([]) ->
	ok;
require([App|Tail]) ->
	case application:start(App) of
		ok -> ok;
		{error, {already_started, App}} -> ok
	end,
	require(Tail).
