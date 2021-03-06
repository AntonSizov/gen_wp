-module(gen_wp_forked).

-behaviour(gen_server).

-export([
	start_link/3
]).
-export([
	init/1,
	handle_call/3,
	handle_cast/2,
	handle_info/2,
	terminate/2,
	code_change/3
]).

-include("gen_wp_types.hrl").

-record(s_cast, {
	wp :: pid(),
	mod :: module_spec(),
	arg :: term(),
	msg :: term()
	}).

-record(s_call, {
	wp :: pid(),
	mod :: module_spec(),
	arg :: term(),
	req :: term(),
	reply_to :: term()
	}).

-spec start_link
	( term(), { atom(), term() }, { cast, term() } ) -> { ok, pid() };
	( term(), { atom(), term() }, { call, { pid(), term() }, term() } ) -> { ok, pid() }.
start_link( WP, { Mod, Arg }, { cast, ForkMessage } ) ->
	gen_server:start_link( ?MODULE, { cast, WP, { Mod, Arg }, ForkMessage }, [] );

start_link( WP, { Mod, Arg }, { call, ReplyTo, ForkRequest } ) ->
	gen_server:start_link( ?MODULE, { call, WP, { Mod, Arg }, ReplyTo, ForkRequest }, [] ).

-spec init
	( { cast, term(), { atom(), term() }, term() } ) -> { ok, #s_cast{} };
	( { call, term(), { atom(), term() }, { pid(), term() }, term() } ) -> { ok, #s_call{} }.
init({ cast, WP, { Mod, Arg }, ForkMessage }) ->
	{ ok, #s_cast{
		wp = WP,
		mod = Mod,
		arg = Arg,
		msg = ForkMessage
	} };

init({ call, WP, { Mod, Arg }, ReplyTo, ForkRequest }) ->
	{ 'gen_wp.reply_to', { LinkTo, _ } } = ReplyTo,
	true = erlang:link( LinkTo ),

	{ ok, #s_call{
		wp = WP,
		mod = Mod,
		arg = Arg,
		req = ForkRequest,
		reply_to = ReplyTo
	} }.

-spec handle_call( term(), { pid(), term() }, term() ) ->
	{ stop, { badarg, term() }, term() }.
handle_call( Request, _From, State ) ->
	{ stop, { badarg, Request}, State}.

-spec handle_cast( 'gen_wp_forked.process', #s_cast{} | #s_call{} ) ->
	{ stop, term(), #s_cast{} } |
	{ stop, { bad_return_value, term() }, #s_cast{} };
				( term(), term() ) ->
	{ stop, { badarg, term() }, term() }.
handle_cast( 'gen_wp_forked.process', State = #s_cast{
		wp = WP,
		mod = Mod,
		arg = Arg,
		msg = Msg
	} ) ->
	case catch Mod:handle_fork_cast( Arg, Msg, WP ) of
		{ noreply, Result } ->
			{ stop, Result, State };
		Else ->
			{ stop, { bad_return_value, Else }, State }
	end;

handle_cast( 'gen_wp_forked.process', State = #s_call{
		wp = WP,
		mod = Mod,
		arg = Arg,
		req = Req,
		reply_to = ReplyTo
	} ) ->
	case catch Mod:handle_fork_call( Arg, Req, ReplyTo, WP ) of
		{ noreply, Result } ->
			{ stop, Result, State };
		{ reply, ReplyWith, Result } ->
			gen_wp:reply( ReplyTo, ReplyWith ),
			{ stop, Result, State };
		Else ->
			{ stop, { bad_return_value, Else }, State }
	end;

handle_cast( Request, State ) ->
	{ stop, { badarg, Request }, State }.

-spec handle_info( term(), term() ) ->
	{ stop, { badarg, term() }, term() }.
handle_info( Message, State ) ->
	{ stop, { badarg, Message }, State }.

-spec terminate( term(), term() ) -> ignore.
terminate( _Reason, _State ) ->
	ok.

-spec code_change( term(), term(), term() ) -> { ok, term() }.
code_change( _OldVsn, State, _Extra ) ->
	{ ok, State }.

