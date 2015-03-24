%% - Server module
%% - The server module creates a parallel registered process by spawning a process which 
%% evaluates initialize(). 
%% The function initialize() does the following: 
%%      1/ It makes the current process as a system process in order to trap exit.
%%      2/ It creates a process evaluating the store_loop() function.
%%      4/ It executes the server_loop() function.

-module(server).

-export([start/0]).

%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
start() -> 
    register(transaction_server, spawn(fun() ->
                           process_flag(trap_exit, true),
                           Val= (catch initialize()),
                           io:format("Server terminated with:~p~n",[Val])
                       end)).

initialize() ->
    process_flag(trap_exit, true),
    Initialvals = [{a, {readlock, 0}, {writelock, 0}, 0},
                   {b, {readlock, 0}, {writelock, 0}, 0},
                   {c, {readlock, 0}, {writelock, 0}, 0},
                   {d, {readlock, 0}, {writelock, 0}, 0}], %% All variables are set to 0
    ServerPid = self(),
    StorePid = spawn_link(fun() -> store_loop(ServerPid,Initialvals) end),
    server_loop([],StorePid, []).
%%%%%%%%%%%%%%%%%%%%%%% STARTING SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% - The server maintains a list of all connected clients and a store holding
<<<<<<< HEAD
%% the values of the global variable a, b, c and d 
server_loop(ClientList,StorePid,TransState) ->
    io:format("Transaction State: ~p.~n", [TransState]),
=======
%% the values of the global variable a, b, c and d
server_loop(ClientList,StorePid) ->
>>>>>>> 9701068154275da15ea490e09fb1949491890f96
    receive
    {login, MM, Client} -> 
        MM ! {ok, self()},
        io:format("New client has joined the server:~p.~n", [Client]),
        StorePid ! {print, self()},
        server_loop(add_client(Client,ClientList),StorePid,TransState);
    {close, Client} -> 
        io:format("Client~p has left the server.~n", [Client]),
        StorePid ! {print, self()},
        server_loop(remove_client(Client,ClientList),StorePid,TransState);
    {request, Client} -> 
        Client ! {proceed, self()},
        server_loop(ClientList,StorePid,[{Client, []}|TransState]);
    {confirm, Client, NumActions} -> 
        case length(get_actions(Client, TransState)) of  
		NumActions -> 
			StorePid ! {actions,self()},
			Client ! {committed,self()},			
			io:format("All actions received.~n");
		true -> 
			Client ! {abort,self()},
			io:format("Not all actions received.~n")
	end,
        server_loop(ClientList,StorePid,delete_actions(Client,TransState));
    {action, Client, Act} ->
        io:format("Received~p from client~p.~n", [Act, Client]),
        server_loop(ClientList,StorePid,add_action(Client,Act,TransState))
    after 50000 ->
    case all_gone(ClientList) of
<<<<<<< HEAD
        true -> exit(normal);    
        false -> server_loop(ClientList,StorePid,TransState)
=======
        true -> exit(normal);
        false -> server_loop(ClientList,StorePid)
>>>>>>> 9701068154275da15ea490e09fb1949491890f96
    end
    end.

%% - The values are maintained here
store_loop(ServerPid, Database) -> 
    receive
    {print, ServerPid} -> 
        io:format("Database status:~n~p.~n",[Database]),
        store_loop(ServerPid,Database)
    end.
%%%%%%%%%%%%%%%%%%%%%%% ACTIVE SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%



%% - Low level function to handle lists
add_client(C,T) -> [C|T].

remove_client(_,[]) -> [];
remove_client(C, [C|T]) -> T;
remove_client(C, [H|T]) -> [H|remove_client(C,T)].

add_action(C,A,[]) -> [];
add_action(C,A,[{C,Actions}|T]) -> [{C,[A|Actions]}|T];
add_action(C,A,[{H,Actions}|T]) -> [{H,Actions}|add_action(C,A,T)].

delete_actions(C,[]) -> [];
delete_actions(C,[{C,Actions}|T]) -> T;
delete_actions(C,[{H,Actions}|T]) -> [{H,Actions}|delete_actions(C,T)].

get_actions(C,[]) -> [];
get_actions(C,[{C,Actions}|T]) -> Actions;
get_actions(C,[{H,Actions}|T]) -> get_actions(C,T).

all_gone([]) -> true;
all_gone(_) -> false.
