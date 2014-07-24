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
-include("enums.hrl").

-import(parser).

%% Handling:
-export([start_link/1]).

%% Callbacks:
-export([init/1, terminate/2]).
-export([handle_call/3, handle_info/2, handle_cast/2]).
-export([code_change/3]).


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
init([Socket]) ->
	report(1, "IO started"),
	{ok, #state{socket=Socket, buffer = <<>>}}.

handle_call(Data, _From, State) ->
	report(0, "Wrong sync event in IO", Data),
	{reply, ok, State}.

handle_cast({login, Name, Password}, State) ->
	report(1, "handle_cast LOGIN"),
	case login(State#state.socket, Name, Password) of
		{error} ->
			report(1, "Wrong auth data", {Name, Password}),
			{noreply, State};
		{ok, Id} ->
			report(1, "User successfully logined in", {Id, Name, Password}),
			NewState = State#state{user_id=Id},
			{noreply, NewState}
	end;
handle_cast({register, Name, Password}, State) ->
	report(1, "handle_cast REGISTER"),
	case register(State#state.socket, Name, Password) of
		{error} ->
			report(1, "Duplicate user name", {Name, Password}),
			{noreply, State};
		{ok, Id} ->
			report(1, "New user successfully registered", {Id, Name, Password}),
			NewState = State#state{user_id=Id},
			{noreply, NewState}
	end;
handle_cast({new_table, TableId, Time, Name, Description}, State) ->
	report(1, "handle_cast NEW_TABLE"),
	new_table(State#state.socket, State#state.user_id, TableId, Time, Name, Description),
	{noreply, State};
handle_cast({new_task, TaskId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime}, State) ->
	report(1, "handle_cast NEW_TASK"),
	new_task(State#state.socket, State#state.user_id, TaskId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime),
	{noreply, State};
handle_cast({new_commentary, TableId, TaskId, Time, Commentary}, State) ->
	report(1, "handle_cast NEW_COMMENTARY"),
	ok = new_commentary(State#state.user_id, TableId, TaskId, Time, Commentary),
	{noreply, State};
handle_cast({table_change, TableId, Time, Name, Description}, State) ->
	report(1, "handle_cast TABLE_CHANGE"),
	ok = table_change(State#state.user_id, TableId, Time, Name, Description),
	{noreply, State};
handle_cast({task_change, TaskId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime}, State) ->
	report(1, "handle_cast TASK_CHANGE"),
	ok = task_change(State#state.user_id, TableId, TaskId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime),
	{noreply, State};
handle_cast({permission_change, TableId, ReaderId, Permission}, State) ->
	report(1, "handle_cast PERMISSION"),
	ok = permission_change(State#state.user_id, TableId, ReaderId, Permission),
	{noreply, State};
handle_cast({send, Type, Data}, State) ->
	send(Type, Data, State#state.socket),
	{noreply, State};
handle_cast(Data, State) ->
	report(1, "Wrong cast event on IO", Data),
	{stop, normal, State}.

%% @hidden
handle_info({tcp, _Socket, Message}, State) ->
	{ok, NewBuffer} = proceed(Message, State#state.buffer),
	{noreply, State#state{buffer=NewBuffer}};
handle_info({tcp_closed, Socket}, State) ->
	report(1, "TCP connection was closed", Socket),
	{stop, normal, State};
handle_info({tcp_error, Socket}, State) ->
	report(1, "TCP error occured", Socket),
	{stop, normal, State}.

%% @hidden
terminate(Reason, State) ->
	report(1, "Terminating IO"), 
	report(2, "Reason", Reason),
	logout(State#state.user_id),
	ok.

%% @hidden
code_change(_, State, _) ->
	report(1, "Code changing in IO"),
	{ok, State}.

%%% @spec proceed(Message, Buffer) -> Result
%%%     Result = {ok, NewBuffer}
%%%       NewBuffer = binary (left data from proceeded Buffer)
%%%
%%% @doc Handling received from client packets
proceed(Message, Buffer) ->
	NewBuffer = <<Buffer/binary, Message/binary>>,
	report(1, "New packet was received", NewBuffer),
	BufferSize = bit_size(NewBuffer),
	report(1, "Size of the handled packets", BufferSize),
	if
		BufferSize > ?TYPE_SIZE + ?PACKET_SIZE ->    %%% Check if we recieved type and size of the packet
			<<Type:?TYPE_SIZE, Size:?PACKET_SIZE, Data/binary>> = NewBuffer,  %%% extract type, size and recieved data of the packet
			report(1, "Packet size", Size),
			if
				BufferSize >= ?PACKET_SIZE + ?TYPE_SIZE + Size -> %%% check if we received whole packet
					<<Packet:Size/bitstring, LeftData/binary>> = Data,
					report(1, "Packet data", Packet),
					handle_packet(Type, Packet), %%% parse data from packet and get new state
					{ok, LeftData};              %%% saving new buffer
				true->
					{ok, NewBuffer}
			end;
		true ->
			{ok, NewBuffer}
	end.

%%% @doc Parse client data by packet type
handle_packet(Type, Packet) when Type =:= ?CLIENT_REGISTER ->
	{Name, Password} = parser:parse("SS", Data),
	do_register(Name, Password);
handle_packet(Type, Packet) when Type =:= ?CLIENT_LOGIN ->
	{Name, Password} = parser:parse("SS", Data),
	do_login(Name, Password);
handle_packet(Type, Packet) when Type =:= ?CLIENT_NEW_TABLE ->
	{TableId, Time, Name, Description} = parser:parse("ILSS", Data),
	create_new_table(TableId, Time, Name, Description);
handle_packet(Type, Packet) when Type =:= ?CLIENT_NEW_TASK ->
	{TaskId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime} = parser:parse("IILSSs8s8"),
	create_new_task(TaskId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime);
handle_packet(Type, Packet) when Type =:= ?CLIENT_TABLE_CHANGE ->
	{TableId, Time, Name, Description} = parser:parse("ILSS", Data),
	do_change_table(TableId, Time, Name, Description);
handle_packet(Type, Packet) when Type =:= ?CLIENT_TASK_CHANGE ->
	{TaskId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime} = parser:parse("IILSSs8s8"),
	do_change_task(TaskId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime);
handle_packet(Type, Packet) when Type =:= ?CLIENT_PERMISSION ->
	{TableId, UserId, Permission} = parser:parse("IIB", Data),
	do_change_permission(TableId, UserId, Permission);
handle_packet(Type, Packet) when Type =:= ?CLIENT_COMMENTARY ->
	{TableId, TaskId, Time, Commentary} = parser:parse("IILS"),
	create_new_commentary(TableId, TaskId, Time, Commentary);
handle_packet(Type, _) ->
	report(1, "Wrong packet type", Type),
	{stop, normal}.

%%% @doc Sends message to socket
send(Type, Data, Socket) ->
	report(1, "Sending back", Data),
	Size = bit_size(Data),
	gen_tcp:send(Socket, <<Type:?TYPE_SIZE, Size:?PACKET_SIZE, Data/binary>>).

do_login(Name, Password) ->
	gen_server:cast(self(), {login, Name, Password}).
do_register(Name, Password) ->
	gen_server:cast(self(), {register, Name, Password}).
create_new_table(TaskId, Time, Name, Description) ->
	gen_server:cast(self(), {new_table, TaskId, Time, Name, Description}).
create_new_task(TaskId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime) ->
	gen_server:cast(self(), {new_task, TaskId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime}).
create_new_commentary(TableId, TaskId, Time, Commentary) ->
	gen_server:cast(self(), {new_commentary, TableId, TaskId, Time, Commentary}).
do_change_table(TableId, Time, Name, Description) ->
	gen_server:cast(self(), {table_change, TableId, Time, Name, Description}).
do_change_task(TaskId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime) ->
	gen_server:cast(self(), {task_change, TaskId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime}).
do_change_permission(TableId, UserId, Permission) ->
	gen_server:cast(self(), {permission_change, TableId, UserId, Permission}).

register(Socket, Name, Password) ->
	report(1, "Registering", Name),
	case database:check_username(Name) of
		error ->
			database:register(Name, Password),
			report(1, "New user registered", Name),
			send(?SERVER_REGISTER, <<?REGISTER_SUCCESS:8>>, Socket),
			login(Socket, Name, Password);
		_ ->
			send(?SERVER_REGISTER, <<?REGISTER_FAILURE:8>>, Socket),
			{error}
	end.

login(Socket, Name, Password) ->
	report(1, "Logining in", Name),
	case database:auth(Name, Password) of
		error ->
			Answer = <<?LOGIN_FAILURE:8>>,
			send(?SERVER_LOGIN, Answer, Socket),
			{error};
		{ok, Id} ->
			Answer = <<?LOGIN_SUCCESS:8, Id:?ID_LENGTH>>,
			report(1, "User logined in", Name),
			send(?SERVER_LOGIN, Answer, Socket),
			clients:add(Id, self()),
			{ok, Id}
	end.

new_table(Socket, UserId, TableClientId, Time, Name, Description) ->
	{ok, TableId} = database:create_new_table(UserId, Time, Name, Description),
	send(?SERVER_GLOBAL_TABLE, <<TableClientId:?ID_LENGTH, TableId:?ID_LENGTH>>, Socket),
	clients:update(table, {TableId, Time, UserId, Name, Description}).
new_task(Socket, UserId, TaskClientId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime) ->
	{ok, TaskId} = database:create_new_task(UserId, TableId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime),
	send(?SERVER_GLOBAL_TASK, <<TaskClientId:?ID_LENGTH, TaskId:?ID_LENGTH, TableId:?ID_LENGTH>>, Socket),
	clients:update(task, {TableId, TaskId, Time, UserId, Name, Description, StartDate, EndDate, StartTime, EndTime}).
new_commentary(UserId, TableId, TaskId, Time, Commentary) ->
	case database:check_permission(UserId, TableId, ?PERMISSION_READ) of
		true ->
			database:create_commentary(UserId, TableId, TaskId, Time, Commentary),
			clients:update(comment, {TableId, TaskId, Time, UserId, Commentary});
		false ->
			report(1, "User do not have permission to create commentary", {UserId, TableId})
	end.
table_change(UserId, TableId, Time, Name, Description) ->
	case database:check_permission(UserId, TableId, ?PERMISSION_WRITE) of
		true ->
			database:change_table(UserId, TableId, Time, Name, Description),
			clients:update(table, {TableId, Time, UserId, Name, Description});
		false ->
			report(1, "User do not have permission to change table", {UserId, TableId})
	end.
task_change(UserId, TableId, TaskId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime) ->
	case database:check_permission(UserId, TableId, ?PERMISSION_WRITE) of
		true ->
			database:change_task(UserId, TableId, TaskId, Time, Name, Description, StartDate, EndDate, StartTime, EndTime),
			clients:update(task, {TableId, TaskId, Time, UserId, Description, StartDate, EndDate, StartTime, EndTime});
		false ->
			report(1, "User do not have permission to change task", {UserId, TableId})
	end.
permission_change(UserId, TableId, ReaderId, Permission) ->
	case database:check_permission(UserId, TableId, ?PERMISSION_WRITE) of
		true ->
			database:change_permission(UserId, TableId, ReaderId, Permission),
			clients:update(permission, {TableId, UserId, ReaderId, Permission});
		false ->
			report(1, "User do not have permission to change permissions", {UserId, TableId})
	end.

logout(UserId) ->
	if 
		UserId == undefined -> ok;
		true -> clients:remove(UserId)
	end.