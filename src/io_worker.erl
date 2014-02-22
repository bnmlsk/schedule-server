%%
%%  Copyright (C) 2013-2014 Elizaveta Lukicheva.
%%
%%  This file is part of Schedule Server.
%%
%%  Schedule Server is free software: you can redistribute it and/or modify
%%  it under the terms of the GNU General Public License as published by
%%  the Free Software Foundation, either version 3 of the License, or
%%  (at your option) any later version.
%%
%%  Schedule Server is distributed in the hope that it will be useful,
%%  but WITHOUT ANY WARRANTY; without even the implied warranty of
%%  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%  GNU General Public License for more details.
%%
%%  You should have received a copy of the GNU General Public License
%%  along with Schedule Server.  If not, see <http://www.gnu.org/licenses/>.

%%  Author: Elizaveta Lukicheva <mailto: liza.lukicheva@gmail.com>
%%  License: <http://www.gnu.org/licenses/gpl.html>

%% @author Elizaveta Lukicheva <liza.lukicheva@gmail.com>
%% @copyright 2013-2014 Elizaveta Lukicheva
%% @doc This is the tier 1 Schedule Server packet processor. It receives a raw
%% message from the supervisor (and supervisor receives
%% it from the acceptor) and handles it.

-module(io_worker).
-behaviour(gen_server).
-include("types.hrl").

%% Handling:
-export([start_link/1]).

%% Callbacks:
-export([init/1, terminate/2]).
-export([handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3]).

do_recv(Socket, Bs) ->
    case gen_tcp:recv(Socket, 0) of
        {ok, B} ->
            do_recv(Socket, [Bs, B]);
        {error, closed} ->
            {ok, list_to_binary(Bs)}
    end.

process(Socket) ->
  receive
    {tcp, Socket, Data} ->
      report(1, "New data was received", Data),
      gen_tcp:send(Socket, Answer),
      process(Socket);
    {tcp_closed, Socket} ->
      report(1, "TCP connection was closed", Socket),
      ok
  end.

%%% @spec start_link() -> Result
%%%    Result = {ok,Pid} | ignore | {error,Error}
%%%     Pid = pid()
%%%     Error = {already_started,Pid} | term()
%%%  
%%% @doc Creates new Schedule Server packet processor.
%%%
start_link(Socket) ->
  gen_server:start_link(io_worker, [Socket], []).

%% Callbacks:

%% @doc Initializes random generator.
init([Socket]) ->
  gen_server:cast(self(), process),
  report(1, "IO started"),
  {ok, #state{socket=Socket}}.

handle_cast(process, State = #state{socket=Socket}) ->
  report(1, "Cast"),
  process(Socket),
  {stop, normal, State}.

handle_call(Data, _, State) ->
  report(0, "Wrong sync event in IO",Data),
  {reply, ok, State}.

%% @hidden
handle_info({tcp, Socket, Message}, State) ->
  report(1, "Some data", Message),
  gen_tcp:send(Socket, Message),
  {noreply, State};
handle_info({tcp_closed, Socket}, State) ->
  report(1, "TCP connection was closed", Socket),
  {stop, normal, State};
handle_info({tcp_error, Socket}, State) ->
  report(1, "TCP error occured", Socket),
  {stop, normal, State}.

%% @hidden
terminate(Reason, _) ->
  report(1, "Terminating IO"), 
  report(2, "Reason", Reason),
  ok.

%% @hidden
code_change(_, State, _) ->
  report(1, "Code changing in IO"),
  {ok, State}.