-module(gen_wp_fork_sup).

-behaviour(supervisor).

%% API
-export([
	start_link/3
]).

%% supervisor callbacks
-export([ init/1 ]).

-include("gen_wp_types.hrl").

%% ===================================================================
%% API
%% ===================================================================

-spec start_link( WP :: pid(), Mod :: module_spec(), Arg :: term() ) -> { ok, pid() }.
start_link( WP, Mod, Arg ) ->
    supervisor:start_link( ?MODULE, { WP, { Mod, Arg } } ).

%% ===================================================================
%% supervisor callbacks
%% ===================================================================

-spec init(term()) -> ignore.
init( { WP, { Mod, Arg } } ) ->
	{ok, {
		{ simple_one_for_one, 1, 1 }, [
			{ forked_worker,
				{ gen_wp_forked, start_link, [ WP, { Mod, Arg } ] }, temporary, brutal_kill, worker, [ gen_wp_forked ]}
		]}
	}.
