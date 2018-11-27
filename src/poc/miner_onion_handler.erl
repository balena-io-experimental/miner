%%%-------------------------------------------------------------------
%% @doc
%% == Miner Onion Stream Handler ==
%% @end
%%%-------------------------------------------------------------------
-module(miner_onion_handler).

-behavior(libp2p_framed_stream).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([
    server/4
    ,client/2
    ,send/2
]).

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Exports
%% ------------------------------------------------------------------
-export([
    init/3
    ,handle_data/3
    ,handle_info/3
]).

-record(state, {}).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------
client(Connection, Args) ->
    libp2p_framed_stream:client(?MODULE, Connection, Args).

server(Connection, Path, _TID, Args) ->
    libp2p_framed_stream:server(?MODULE, Connection, [Path | Args]).

send(Pid, Data) ->
    Pid ! {send, Data}.

%% ------------------------------------------------------------------
%% libp2p_framed_stream Function Definitions
%% ------------------------------------------------------------------
init(client, _Conn, _Args) ->
    lager:info("started ~p client", [?MODULE]),
    {ok, #state{}};
init(server, _Conn, _Args) ->
    lager:info("started ~p server", [?MODULE]),
    {ok, #state{}}.

handle_data(client, Data, State) ->
    lager:info("client got data: ~p", [Data]),
    {noreply, State};
handle_data(server, Data, State) ->
    ok = miner_onion_server:decrypt(Data),
    {noreply, State}.

handle_info(client, {send, Data}, State) ->
    lager:info("client sending data: ~p", [Data]),
    {noreply, State, Data};
handle_info(_Type, _Msg, State) ->
    lager:info("rcvd unknown type: ~p unknown msg: ~p", [_Type, _Msg]),
    {noreply, State}.