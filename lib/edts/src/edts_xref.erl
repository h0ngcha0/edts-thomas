%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc xref-library for edts.
%%% @end
%%% @author Thomas Järvstrand <tjarvstrand@gmail.com>
%%% @copyright
%%% Copyright 2012 Thomas Järvstrand <tjarvstrand@gmail.com>
%%%
%%% This file is part of EDTS.
%%%
%%% EDTS is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% EDTS is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with EDTS. If not, see <http://www.gnu.org/licenses/>.
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration =======================================================
-module(edts_xref).

%%%_* Exports ==================================================================

-export([ get_function_info/3
        , get_module_info/1
        , get_module_info/2
        , modules/0
        , start/0]).

%%%_* Includes =================================================================

%%%_* Defines ==================================================================
-define(SERVER, ?MODULE).
%%%_* Types ====================================================================

%%%_* API ======================================================================

%%------------------------------------------------------------------------------
%% @doc
%% Returns information about Function as defined in Module.
%% @end
-spec get_function_info(M::module(), F0::atom(), A0::non_neg_integer()) ->
                  {ok, [{atom(), term()}]}
                | {error, atom()}.
%%------------------------------------------------------------------------------
get_function_info(M, F0, A0) ->
  {M, Bin, _File}                   = code:get_object_code(M),
  {ok, {M, Chunks}}                 = beam_lib:chunks(Bin, [abstract_code]),
  {abstract_code, {_Vsn, Abstract}} = lists:keyfind(abstract_code, 1, Chunks),
  InfoFun = fun({attribute, _Line, export}, Acc) ->
                orddict:store(exported, lists:member({F0, A0}, Acc));
               ({function, Line, F, A, _Clauses}, Acc) when F =:= F0 andalso
                                                            A =:= A0 ->
                throw({done, orddict:store(line_start, Line, Acc)});
               ({attribute, _Line, file, {Source, _Line}}, Acc) ->
                orddict:store(source_file, Source, Acc);
               (_, Acc) -> Acc
            end,
  Dict0 = orddict:from_list([{module,   M}
                          , {function, F0}
                          , {arity,    A0}
                          , {exported, false}]),
  Dict = try lists:foldl(InfoFun, Dict0, Abstract)
         catch throw:{done, Dict1} -> Dict1
         end,
  %% Get rid of any local paths, in case function was defined in a
  %% file include with a relative path.
  SourcePath0 = orddict:fetch(source_file, Dict),
  case filename:absname(SourcePath0) of
    SourcePath0 -> orddict:to_list(Dict);
    SourcePath  ->
      {source, BeamSource} = lists:keyfind(source, 1, M:module_info(compile)),
      RealPath = filename:join(filename:dirname(BeamSource), SourcePath),
      orddict:from_list(orddict:store(source_file, RealPath, Dict))
  end.


%%------------------------------------------------------------------------------
%% @doc
%% Equivalent to get_module_info(M, detailed).
%% @end
-spec get_module_info(M::module()) -> [{atom, term()}].
%%------------------------------------------------------------------------------
get_module_info(M) ->
  get_module_info(M, detailed).

%%------------------------------------------------------------------------------
%% @doc
%% Returns information on M.
%% @end
-spec get_module_info(M::module(), Level::basic | detailed) -> [{atom, term()}].
%%------------------------------------------------------------------------------
get_module_info(M, basic) ->
  Info                         = erlang:get_module_info(M),
  {compile, Compile}           = lists:keyfind(compile, 1, Info),
  {exports, Exports}           = lists:keyfind(exports, 1, Info),
  {time, {Y, Mo, D, H, Mi, S}} = lists:keyfind(time,    1, Compile),
  Ret = [ {module, M}
        , {exports, [[{function, F}, {arity, A}] || {F, A} <- Exports]}
        , {time, {{Y, Mo, D}, {H, Mi, S}}}
        , lists:keyfind(source,  1, Compile)],
  {ok, Ret};
get_module_info(M, detailed) ->
  {M, Bin, _File}                   = code:get_object_code(M),
  {ok, {M, Chunks}}                 = beam_lib:chunks(Bin, [abstract_code]),
  {abstract_code, {_Vsn, Abstract}} = lists:keyfind(abstract_code, 1, Chunks),
  {ok, Basic} = get_module_info(M, basic),

  Acc0 = orddict:from_list([ {imports,   []}
                           , {functions, []}
                           , {records,   []}]
                           ++ Basic),
  Dict0 = lists:foldl(fun parse_abstract/2, Acc0, Abstract),
  Dict  = orddict:update(imports, fun(I) -> ordsets:to_list(I) end, Dict0),
  {ok, orddict:to_list(Dict)}.

parse_abstract({function, Line, F, A, _Clauses}, Acc) ->
  M = orddict:fetch(module, Acc),
  FunInfo =
    [ {module,   M}
    , {function, F}
    , {arity,    A}
    , {exported, lists:member({F, A}, M:module_info(exports))}
    , {source,   orddict:fetch(source, Acc)}
    , {line,     Line}],
  orddict:update(functions, fun(Fs) -> [FunInfo|Fs] end, Acc);
parse_abstract({attribute, _Line0, file, {SourcePath0, _Line1}}, Acc) ->
  %% %% Get rid of any local paths, in case function was defined in a
  %% %% file include with a relative path.
  SourcePath =
    case filename:absname(SourcePath0) of
      SourcePath0 -> SourcePath0;
      SourcePath1  ->
        M = orddict:fetch(module, Acc),
        {source, BeamSource} = lists:keyfind(source, 1, M:module_info(compile)),
        filename:join(filename:dirname(BeamSource), SourcePath1)
    end,
  orddict:store(file, SourcePath, Acc);
parse_abstract({attribute,_Line,import, {Module, Imports}}, Acc) ->
  ImportSet = ordsets:from_list(Imports),
  UpdateFun0 =
    fun(OldImports) ->
        UpdateFun1 = fun(Old) -> ordsets:union(Old, ImportSet) end,
        orddict:update(Module, UpdateFun1, ImportSet, OldImports)
    end,
  orddict:update(imports, UpdateFun0, Acc);
parse_abstract({attribute, Line ,record,{Recordname, Fields}}, Acc) ->
  FieldsF = fun({record_field, _, {_, _, FName}})         -> FName;
                ({record_field, _, {_, _, FName}, _Call}) -> FName
            end,
  RecordInfo =
    [ {name,   Recordname}
      , {fields, lists:map(FieldsF, Fields)}
      , {line,   Line}
      , {source, orddict:fetch(file, Acc)}],
  orddict:update(records, fun(Old) -> [RecordInfo|Old] end, Acc);
parse_abstract(_, Acc) -> Acc.


%%------------------------------------------------------------------------------
%% @doc
%% Returns a list of all modules known to the edts_xref server.
%% @end
-spec modules() -> [atom()].
%%------------------------------------------------------------------------------
modules() ->
  xref:q(?SERVER, '".*" : Mod').

%%------------------------------------------------------------------------------
%% @doc
%% Starts the edts xref-server on the local node.
%% @end
-spec start() -> ok.
%%------------------------------------------------------------------------------
start() ->
  case xref:start(?SERVER) of
    {ok, _Pid}                       -> init();
    {error, {already_started, _Pid}} -> update()
  end,
  load_cache().

%%%_* Internal functions =======================================================

init() ->
  ok = xref:set_default(?SERVER, [{verbose,false}, {warnings,false}]),
  Paths = code:get_path(),
  ok = xref:set_library_path(?SERVER, Paths),
  lists:foreach(fun(D) ->
                    case xref:add_application(?SERVER, filename:dirname(D)) of
                      {error, _, _} -> xref:add_directory(?SERVER, D);
                      {ok, _}       -> ok
                    end
                end,
                Paths).

update() ->
  {ok, _Modules} = xref:update(?SERVER),
  ok.

%% Query the server to cache values.
load_cache() ->
  modules().

%%%_* Emacs ====================================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:

