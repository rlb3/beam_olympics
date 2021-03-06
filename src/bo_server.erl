-module(bo_server).

-behaviour(gen_server).

-export([ start_link/0
        ]).

-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-export([test/3]).

-type state() :: #{}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% External API functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-spec start_link() -> {ok, pid()}.
start_link() ->
  gen_server:start_link(
    {local, ?MODULE}, ?MODULE, noargs, [{debug, [{trace, log}]}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Callback implementation
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec init(noargs) -> {ok, state()}.
init(noargs) ->
  {ok, #{}}.

-spec handle_call
  (stats, {pid(), term()}, state()) ->
    {reply, bo_players_repo:stats(), state()};
  ({signup, term()}, {pid(), term()}, state()) ->
    {reply, {ok, bo_task:task()} | {error, conflict}, state()};
  ({task, bo_players:name()}, {pid(), term()}, state()) ->
    {reply, {ok, bo_task:task()}
          | {error, ended | forbidden | notfound}, state()};
  ({score, bo_players:name()}, {pid(), term()}, state()) ->
    {reply, {ok, integer()} | {error, forbidden | notfound}, state()};
  ({submit, bo_players:name(), term()}, {pid(), term()}, state()) ->
    {reply, {ok, bo_task:task()} | the_end
          | {error, invalid | timeout | ended | forbidden | notfound}
          | {failures, [term(), ...]}, state()};
  ({skip, bo_players:name()}, {pid(), term()}, state()) ->
    {reply, {ok, bo_task:task()} | the_end
          | {error, ended | forbidden | notfound}, state()}.
handle_call(stats, _From, State) ->
  {reply, bo_players_repo:stats(), State};
handle_call({signup, Data}, _From, State) when not is_binary(Data) ->
  {reply, {error, invalid}, State};
handle_call({signup, PlayerName}, {From, _}, State) ->
  Node = node(From),
  try bo_players_repo:signup(PlayerName, Node) of
    Player -> ok = bo_hooks:execute(signedup, [Player]),
              {reply, task(Player), State}
  catch
    _:conflict -> {reply, {error, conflict}, State}
  end;
handle_call({task, PlayerName}, {From, _}, State) ->
  case check_player_and_task(PlayerName, From) of
    {error, Error} -> {reply, {error, Error}, State};
    Player -> {reply, task(Player), State}
  end;
handle_call({score, PlayerName}, {From, _}, State) ->
  case check_player(PlayerName, From) of
    {error, Error} -> {reply, {error, Error}, State};
    Player -> {reply, {ok, bo_players:score(Player)}, State}
  end;
handle_call({submit, PlayerName, Solution}, {From, _} = Caller, State) ->
  case check_player_and_task(PlayerName, From) of
    {error, Error} -> {reply, {error, Error}, State};
    Player ->
      ok = cxy_ctl:execute_task(bo, ?MODULE, test, [Caller, Player, Solution]),
      {noreply, State}
  end;
handle_call({skip, PlayerName}, {From, _}, State) ->
  case check_player_and_task(PlayerName, From) of
    {error, Error} -> {reply, {error, Error}, State};
    Player -> {reply, advance(Player, skip), State}
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Unused Callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec handle_cast(term(), state()) -> {noreply, state()}.
handle_cast(_Msg, State) -> {noreply, State}.
-spec terminate(term(), state()) -> ok.
terminate(_Reason, _State) -> ok.
-spec code_change(term(), state(), term()) -> {ok, state()}.
code_change(_OldVsn, State, _Extra) -> {ok, State}.
-spec handle_info(_, state()) -> {noreply, state()}.
handle_info(_, State) -> {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Cxy Ctl Callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec test({pid(), term()}, bo_players:player(), bo_task:solution()) -> ok.
test(Caller, Player, Solution) ->
  Reply =
    case bo_players_repo:test(Player, Solution) of
      ok -> advance(Player, solve);
      NOK -> NOK
    end,
  _ = gen_server:reply(Caller, Reply),
  ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Internals
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
check_player_and_task(PlayerName, From) ->
  case check_player(PlayerName, From) of
    {error, Error} -> {error, Error};
    Player -> check_task(Player)
  end.

check_player(PlayerName, From) ->
  Node = node(From),
  case bo_players_repo:fetch(PlayerName) of
    notfound -> {error, notfound};
    Player ->
      case bo_players:node(Player) of
        Node -> Player;
        NotNode ->
          error_logger:warning_msg(
            "~p trying to access from ~p but registered at ~p",
            [PlayerName, Node, NotNode]),
          {error, forbidden}
      end
  end.

check_task(Player) ->
  case bo_players:task(Player) of
    undefined -> {error, ended};
    _Task -> Player
  end.

task(Player) -> {ok, bo_task:describe(bo_players:task(Player))}.

advance(Player, Action) ->
  NewPlayer = bo_players_repo:advance(Player, Action),
  ok = bo_hooks:execute(advanced, [Action, NewPlayer]),
  case bo_players:task(NewPlayer) of
    undefined -> ok = bo_hooks:execute(finished, [NewPlayer]),
                 the_end;
    Task -> {ok, bo_task:describe(Task)}
  end.