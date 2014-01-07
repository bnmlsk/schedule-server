%%
%%  Copyright (C) 2013-2014 Elizaveta Lukicheva.
%%
%%  This file is part of Shedule Server.
%%
%%  Shedule Server is free software: you can redistribute it and/or modify
%%  it under the terms of the GNU General Public License as published by
%%  the Free Software Foundation, either version 3 of the License, or
%%  (at your option) any later version.
%%
%%  Shedule Server is distributed in the hope that it will be useful,
%%  but WITHOUT ANY WARRANTY; without even the implied warranty of
%%  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%  GNU General Public License for more details.
%%
%%  You should have received a copy of the GNU General Public License
%%  along with Shedule Server.  If not, see <http://www.gnu.org/licenses/>.

%%  Author: Elizaveta Lukicheva <mailto: liza.lukicheva@gmail.com>
%%  License: <http://www.gnu.org/licenses/gpl.html>

%% @author Elizaveta Lukicheva <liza.lukicheva@gmail.com>
%% @copyright 2013-2014 Elizaveta Lukicheva
%% @doc This is the main Shedule Server server module describes callbacks for 
%% gen_server handling UDP socket for both incoming and outcoming connections.

-module(acceptor).
-behaviour(gen_server).
-include("types.hrl").

%% Callbacks:
-export([terminate/2]).
-export([init/1]).
-export([handle_info/2, handle_call/3, handle_cast/2]).
-export([code_change/3]).

%% Working with the server (starting):
-export([start_link/1]).

%%% @spec start_link(Args) -> Result
%%%    Args = term()
%%%    Result = {ok,Pid} | ignore | {error,Error}
%%%     Pid = pid()
%%%     Error = {already_started,Pid} | term()
%%%
%%% @doc Starts the Shedule TCP server. Args are ignored.
%%% For now server starts in active mode. That means, process
%%% will receive all the packets as Erlang messages, without 
%%% explicit recv/2 using.
%%%
start_link(Args) ->
  report(1, "Starting Shedule acceptor"),
  gen_server:start_link(
    {local, ?MODULE},
    ?MODULE,
    Args, 
    []
  ).

%% Callbacks:  
%% @doc Configures and opens a port and stores it as gen_server internal state.
init(Args) ->
  Port = getenv(tcp_port, "Unable to get TCP port"),
  {ok, Socket} = gen_tcp:listen(Port, [binary, {active, true}]).
  
%% @doc closes port at gen_server shutdown.
terminate(Reason, Socket) ->
  report(1, "Terminating acceptor"), 
  report(2, "Reason", Reason),
  gen_tcp:close(Socket). % closes the socket

%% @doc Handles message from the port. Since server is in active mode, all the messages are 
%% comming to the process as special Erlang messages.
handle_info(Message, {Socket, Acc}) when is_record(Message, tcp) ->
  report(1, "New packet received"),
  report(3, "Message", Message),
  {ok, SocketIo} = gen_tcp:accept(Socket),
  {ok, Child} = io_sup:start_io(SocketIo), %% Making new worker for that packet.
  gen_tcp:controlling_process(SocketIo, Child),
  io:process(Child, Message#tcp.data),
  {noreply, Socket};
  
handle_info(Data, State) ->
  report(0, "Wrong info in Shedule Server acceptor",Data),
  {noreply, State}.
  
%% @hidden
handle_call(Data, _, State) ->
  report(0, "Wrong call in Shedule Server acceptor",Data),
  {reply, unknown, State }.
  
handle_cast(Data, State) ->
  report(0, "Wrong cast in Shedule Server acceptor",Data),
  {noreply, State }.
  
%% @hidden Dummy
code_change(_, State, _) ->
  report(1, "Code change in Shedule Server acceptor"),
  {ok, State }.
