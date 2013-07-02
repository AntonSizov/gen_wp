-module(gen_wp).

-behaviour(gen_server).

-export([
	behaviour_info/1
	]).
-export([
	start_link/2,
	start_link/3,
	start_link/4,
	call/2,
	call/3,
	cast/2,
	reply/2
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
-include("gen_wp.hrl").

-record(s, {
	mod :: module_spec(),
	arg :: any(),
	mod_state :: any(),
	fork_sup :: pid(),
	ctx = #gwp_ctx{} :: #gwp_ctx{}
	}).

%%% Declare behaviour
-spec behaviour_info(callbacks) ->
	[ { atom(), integer() } ].
behaviour_info(callbacks) ->
	[
		{ init, 1 },
		{ handle_cast, 2 },
		{ handle_call, 3 },
		{ handle_info, 2 },
		{ code_change, 3 },
		{ terminate, 2 },
		{ handle_fork_cast, 3 },
		{ handle_fork_call, 4 },
		{ handle_child_forked, 3 },
		{ handle_child_terminated, 4 }
	].

%%% API

-spec start_link( module_spec(), module_arg() ) -> {ok, pid()}.
-spec start_link( module_spec(), module_arg(), [term()] ) -> {ok, pid()}.
-spec start_link( atom(), module_spec(), module_arg(), [term()] ) -> {ok, pid()}.

start_link( Mod, Arg ) ->
	start_link( Mod, Arg, [] ).

start_link( Mod, Arg, Opts ) ->
	PoolSize = proplists:get_value( pool_size, Opts, infinity ),
	gen_server:start_link(?MODULE, { main, Mod, Arg, PoolSize }, proplists:delete(pool_size, Opts) ).

start_link( Reg, Mod, Arg, Opts ) ->
	PoolSize = proplists:get_value( pool_size, Opts, infinity ),
	gen_server:start_link(Reg, ?MODULE, { main, Mod, Arg, PoolSize }, proplists:delete(pool_size, Opts) ).

-type name() :: atom().
-type global_name() :: term().
-type via_name() :: term().
-type server_ref() ::
	name() |
	{ name(), node() } |
	{ global, global_name() } |
	{ via, module(), via_name() } |
	pid().
-type request() :: term().
-type reply() :: term().
-type gwp_timeout() :: pos_integer() | infinity.
-type from() :: { pid(), term() }.

-spec call( server_ref(), request() ) -> reply().
call( Server, Request ) ->
	gen_server:call( Server, { 'gen_wp.call', Request } ).

-spec call( server_ref(), request(), gwp_timeout() ) -> reply().
call( Server, Request, Timeout ) ->
	gen_server:call( Server, { 'gen_wp.call', Request }, Timeout ).

-spec cast( server_ref(), request() ) -> ok.
cast( Server, Message ) ->
	gen_server:cast( Server, { 'gen_wp.cast', Message } ).

-spec reply( { 'gen_wp.reply_to', from() }, term() ) -> term().
reply( { 'gen_wp.reply_to', ReplyTo }, ReplyWith ) ->
	gen_server:reply( ReplyTo, ReplyWith ).

%%% Behave as gen_server

-spec init({ main, atom(), term(), infinity | integer() }) ->
	{ ok, #s{} } |
	{ ok, #s{}, non_neg_integer() | infinity } |
	{ ok, #s{}, hibernate}.
init({ main, Mod, Arg, PoolSize }) ->
	{ok, ForkSup} = gen_wp_fork_sup:start_link( self(), Mod, Arg ),
	Ctx = #gwp_ctx{
		max_pool_size = PoolSize
	},
	case catch Mod:init( Arg ) of
		{ ok, ModState } ->
			{ ok, #s{
				mod = Mod,
				arg = Arg,
				mod_state = ModState,
				fork_sup = ForkSup,
				ctx = Ctx
			} };

		{ ok, ModState, Timeout } ->
			{ ok, #s{
				mod = Mod,
				arg = Arg,
				mod_state = ModState,
				fork_sup = ForkSup,
				ctx = Ctx
			}, Timeout };

		Else ->
			{ stop, { bad_return_value, Else } }
	end.

-spec handle_call( { 'gen_wp.call', request() }, from(), #s{}) ->
	{ reply, from(), #s{} } |
	{ reply, from(), #s{}, timeout() } |
	{ reply, from(), #s{}, hibernate } |
	{ noreply, #s{} } |
	{ noreply, #s{}, timeout() } |
	{ noreply, #s{}, hibernate } |
	{ stop, term(), term(), #s{} } |
	{ stop, term(), #s{} };
				(term(), from(), #s{}) ->
	{ stop, { badarg, term() }, badarg, #s{} }.
handle_call( { 'gen_wp.call', Request }, From, State = #s{
		mod = Mod,
		mod_state = ModState,
		fork_sup = ForkSup,
		ctx = Ctx
	} ) ->
	ReplyTo = { 'gen_wp.reply_to', From },
	case catch Mod:handle_call( Request, ReplyTo, ModState ) of
		{ noreply, NModState } ->
			{ noreply, State #s{ mod_state = NModState } };

		{ noreply, NModState, Timeout } ->
			{ noreply, State #s{ mod_state = NModState }, Timeout };

		{ reply, ReplyWith, NModState } ->
			{ reply, ReplyWith, State #s{ mod_state = NModState } };

		{ reply, ReplyWith, NModState, Timeout } ->
			{ reply, ReplyWith, State #s{ mod_state = NModState }, Timeout };

		{ stop, Reason, ReplyWith, NModState } ->
			{ stop, Reason, ReplyWith, State #s{ mod_state = NModState } };

		{ stop, Reason, NModState } ->
			{ stop, Reason, State #s{ mod_state = NModState } };

		{ fork, ForkRequest, NModState } ->
			Task = { call, ReplyTo, ForkRequest },
			NCtx = handle_task( ForkSup, Task, Ctx ),
			{ noreply, State #s{ mod_state = NModState, ctx = NCtx } };

		{ fork, ForkRequest, NModState, Timeout } ->
			Task = { call, ReplyTo, ForkRequest },
			NCtx = handle_task( ForkSup, Task, Ctx ),
			{ noreply, State #s{ mod_state = NModState, ctx = NCtx }, Timeout };

		Else ->
			{ stop, {bad_return_value, Else}, State }
	end;

handle_call( Request, _From, State = #s{} ) ->
	{ stop, { badarg, Request }, badarg, State }.

-spec handle_cast( { 'gen_wp.child_forked', term(), term() }, #s{} ) ->
	{ noreply, #s{} } |
	{ stop, {bad_return_value, term() }, #s{} };
				( { 'gen_wp.child_terminated', term(), term(), term() }, #s{} ) ->
	{ noreply, #s{} } |
	{ stop, { bad_return_value, term() }, #s{} };
				( { 'gen_wp.cast', term() }, #s{} ) ->
	{ noreply, #s{} } |
	{ noreply, #s{}, timeout() } |
	{ noreply, #s{} } |
	{ noreply, #s{}, timeout() } |
	{ stop, term(), #s{} } |
	{ stop, { bad_return_value, term() }, #s{} };
			( term(), #s{} ) ->
	{ stop, { badarg, term() }, #s{} }.
handle_cast( { 'gen_wp.child_forked', Task, Child }, State = #s{
		mod = Mod,
		mod_state = ModState
	} ) ->
	Message =
	case Task of
		{ cast, Msg } -> Msg;
		{ call, _ , Msg } -> Msg
	end,
	case catch Mod:handle_child_forked( Message, Child, ModState ) of
		{ noreply, NModState } ->
			{ noreply, State#s{ mod_state = NModState } };
		Else ->
			{ stop, {bad_return_value, Else}, State }
	end;
handle_cast({ 'gen_wp.child_terminated', Reason, Task, Child }, State = #s{
		mod = Mod,
		mod_state = ModState
	}) ->
	Message =
	case Task of
		{ cast, Msg } -> Msg;
		{ call, _ , Msg } -> Msg
	end,
	case catch Mod:handle_child_terminated( Reason, Message, Child, ModState ) of
		{ noreply, NModState } ->
			{ noreply, State#s{ mod_state = NModState } };
		Else ->
			{ stop, { bad_return_value, Else }, State }
	end;
handle_cast( { 'gen_wp.cast', Message }, State = #s{
		mod = Mod,
		mod_state = ModState,
		fork_sup = ForkSup,
		ctx = Ctx
	} ) ->
	case catch Mod:handle_cast( Message, ModState ) of
		{ noreply, NModState } ->
			{ noreply, State #s{ mod_state = NModState } };

		{ noreply, NModState, Timeout } ->
			{ noreply, State #s{ mod_state = NModState }, Timeout };

		{ fork, ForkMessage, NModState } ->
			Task = { cast, ForkMessage },
			NCtx = handle_task( ForkSup, Task, Ctx ),
			{ noreply, State #s{ mod_state = NModState, ctx = NCtx } };

		{ fork, ForkMessage, NModState, Timeout } ->
			Task = { cast, ForkMessage },
			NCtx = handle_task( ForkSup, Task, Ctx ),
			{ noreply, State #s{ mod_state = NModState, ctx = NCtx }, Timeout };

		{ stop, Reason, NModState } ->
			{ stop, Reason, State #s{ mod_state = NModState } };

		Else ->
			{ stop, {bad_return_value, Else}, State }
	end;

handle_cast( Message, State = #s{} ) ->
	{ stop, { badarg, Message }, State }.

-spec handle_info( { 'DOWN', reference(), process, pid(), term() }, #s{} ) ->
	{ noreply, #s{} } |
	{ noreply, #s{}, timeout() } |
	{ stop, term(), #s{} } |
	{ noreply, #s{} } |
	{ noreply, #s{}, timeout() } |
	{ stop, { bad_return_value, term() }, #s{} }.
handle_info( Info = {'DOWN', MonRef, process, _Pid, Reason }, State = #s{
		ctx = Ctx,
		fork_sup = ForkSup
	} ) ->
	#gwp_ctx{
		ref_to_pid = Refs,
		pending_tasks = TQueue
	} = Ctx,
	case dict:find( MonRef, Refs ) of
		{ok, { Child, Task } } ->
			gen_server:cast( self(), { 'gen_wp.child_terminated', Reason, Task, Child } ),
			{ MaybeTask, NTQueue } = queue:out( TQueue ),
			NCtx = maybe_handle_task(
				ForkSup, MaybeTask,
				Ctx #gwp_ctx{
					ref_to_pid = dict:erase( MonRef, Refs ),
					pending_tasks = NTQueue
				} ),

			{ noreply, State #s{ ctx = NCtx } };
		error ->
			handle_info_passthru( Info, State )
	end;

handle_info( Info, State = #s{} ) ->
	handle_info_passthru( Info, State ).

-spec terminate( term(), #s{} ) -> ignore.
terminate( Reason, #s{
	mod = Mod,
	mod_state = ModState
} ) ->
	Mod:terminate( Reason, ModState ).

-type vsn() ::
	term() | { down, term() }.
-spec code_change( vsn(), #s{}, term() ) ->
	{ ok, #s{} } |
	{ error, term() }.
code_change(
	OldVsn,
	State = #s{
		mod = Mod,
		mod_state = ModState
	},
	Extra
) ->
	{ ok, NModState } = Mod:code_change( OldVsn, ModState, Extra ),
	{ ok, State #s{ mod_state = NModState } }.


%%% Internals

handle_info_passthru( Info, State = #s{
		mod = Mod,
		mod_state = ModState,
		fork_sup = ForkSup,
		ctx = Ctx
	} ) ->
		case catch Mod:handle_info( Info, ModState ) of
			{ noreply, NModState } ->
				{ noreply, State #s{ mod_state = NModState } };
			{ noreply, NModState, Timeout } ->
				{ noreply, State #s{ mod_state = NModState }, Timeout };
			{ stop, Reason, NModState } ->
				{ stop, Reason, State #s{ mod_state = NModState } };

			{ fork, ForkInfo, NModState } ->
				Task = { cast, ForkInfo },
				NCtx = handle_task( ForkSup, Task, Ctx ),
				{ noreply, State #s{ mod_state = NModState, ctx = NCtx } };
			{ fork, ForkInfo, NModState, Timeout } ->
				Task = { cast, ForkInfo },
				NCtx = handle_task( ForkSup, Task, Ctx ),
				{ noreply, State #s{ mod_state = NModState, ctx = NCtx }, Timeout };

			Else ->
				{ stop, {bad_return_value, Else}, State }
		end.

maybe_handle_task( _ForkSup, empty, Ctx ) -> Ctx;
maybe_handle_task( ForkSup, { value, Task }, Ctx ) ->
	handle_task( ForkSup, Task, Ctx ).

handle_task(
	ForkSup, Task,
	Ctx = #gwp_ctx{
		pending_tasks = PendingTasks,
		max_pool_size = MaxPoolSize,
		ref_to_pid = Refs
	}
) ->
	PoolSize = dict:size( Refs ),
	if
		MaxPoolSize == infinity orelse
		MaxPoolSize > PoolSize ->
			{ok, Child} = supervisor:start_child( ForkSup, [ Task ] ),
			MonRef = erlang:monitor( process, Child ),
			gen_server:cast( self(), { 'gen_wp.child_forked', Task, Child } ),
			gen_server:cast( Child, 'gen_wp_forked.process' ),
			Ctx #gwp_ctx{ ref_to_pid = dict:store( MonRef, {Child, Task}, Refs ) };
		true ->
			Ctx #gwp_ctx{ pending_tasks = queue:in( Task, PendingTasks ) }
	end.

