(*
  Driver.ml
  
  The primary interface to the dbtoaster compiler; Compiles into dbtoaster
  
  Most of Driver is just glue code and parameter parsing options; The process
  can be broken down into roughly 5 stages:
  
  1 - Parse user options.  Self explanatory.  For a full rundown, compile
      and run './dbtoaster -?'  Among other things, this is where we learn
      what language the user wants to compile into.  This is also where we
      figure out where to output.  The global 'output_file' variable is set to
      the appropriate output stream.
      
  2 - Translate SQL to Calculus.  Most of the heavy lifting here is done by
      ocaml's builtin Parsing module, and the lexing/parsing modules in the
      parser subdirectory (in particular Sqlparser).  
      
      After this phase we are left with a list of querysets (one per input
      file).  Each queryset contains a list of queries, a schema, and a list of
      relation input sources (M3.relation_input_t).  
      
      If the user indicates that they want their output in relational calculus
      form (ie, "-l calc" is passed in on the command line), convert the 
      generated formula to a string, dump it into the output file, and exit.
  
  3 - Translate Calculus to M3.  This is where most of the exciting stuff takes
      place.  Most of the heavy lifting is done by the Compiler and CalcToM3 
      modules: Compiler.compile and CalcToM3.M3InProgress.generate_m3.  
      compile, when invoked with generate_m3 will output an M3InProgress.t that
      we can repeatedly invoke Compiler.compile on.  
      
      Compiler.compile is invoked once per query (recall, queries are stored 
      under 2 levels of list nesting), and an M3.prog_t is extracted from the
      result.
      
  4 - Translate M3 to the target language.  If the target language is M3, then
      we just need to turn it into a string before outputting it.  Otherwise,
      we need to do some code generation.  The heavy lifting here is done by
      the M3Compiler module parametrized by an M3Codegen.
      
      Each subdirectory of the codegen directory contains a subclass of 
      M3Codegen.  Parametrized appropriately, M3Compiler translates an M3.prog_t
      and a set of relation input sources (obtained in step 2) into the target
      language.  Currently, support exists for compiling into:
        - OCAML
      
      Unless "-l none" is specified, the compiler will compile the M3 program 
      and output to the designated output_file (with one caveat, see step 5).
      
  5 - Invoke the secondary compiler.  If the target language is one with its own
      (external) compiler (eg, Ocaml / C++), dbtoaster can be invoked with the
      "-c" flag.  As a convenience, the "-c" flag will invoke the external 
      compiler on the generated source file.  
      
      If no output file is specified for the target language (or if outputting 
      to stdout), the M3->Target compiler will be invoked to produce output to 
      a temporary file.  Consequently, unless explicitly directed to output to
      stdout "-o -", only the temporary file will be produced (ie, the target
      language output will not be dumped to stdout if "-c" is used).
*)

open Util

let print_line x = print_string (x^"\n");;

let valid_langs = 
  List.fold_left (fun accum x -> StringSet.add x accum) StringSet.empty [
    "calculus"; "m3"; "ocaml"; "c++"
  ]

(********* PARSE ARGUMENTS *********)

type flag_type_t = NO_ARG | OPT_ARG | ARG | ARG_LIST

let flag_descriptors = 
  ParseArgs.compile
    [ (["-l";"--lang"], 
          ("LANG",    ParseArgs.ARG), "ocaml|cpp|calc|m3",
          "Specify the output language (default: ocaml).");
      (["-o";"--output-source"],
          ("OUTPUT",  ParseArgs.ARG), "<outfile>",
          "Output source file to <outputfile> (default: stdout)." );
      (["-c";"--compile-binary"],
          ("COMPILE", ParseArgs.ARG), "<binary_file>",
          "Invoke secondary compiler to compile to a runnable binary." );
      (["-d"],
          ("DEBUG",   ParseArgs.ARG_LIST), "<flag> [-d <flag> [...]]",
          "Enable a debug flag." );
      (["-?";"--help"], 
          ("HELP",    ParseArgs.NO_ARG),  "", 
          "Display this help text." );
    ];;

let arguments = ParseArgs.parse flag_descriptors;;

(********* UTILITIES FOR ACCESSING FLAGS *********)

(* Initialize Util.ParseArgs *)
let (flag_vals, flag_val, flag_val_force, flag_set, flag_bool) = 
  ParseArgs.curry arguments;;

(* Initialize Util.Debug *)
Debug.set_modes (flag_set "DEBUG");

if flag_bool "HELP" then
  (
    print_string (ParseArgs.helptext arguments flag_descriptors);
    exit 0
  )
else ();;

(********* EXTRACT/VALIDATE COMMAND LINE ARGUMENTS *********)

let input_files = if (flag_bool "FILES") then flag_vals "FILES" 
                  else give_up "No files provided";;
    
type language_t = L_OCAML | L_CPP | L_SQL | L_CALC | L_M3 | L_NONE;;

let language = match flag_val "LANG" with
  | None -> L_OCAML
  | Some(a) -> match String.uppercase a with
    | "OCAML"    -> L_OCAML
    | "C++"      -> L_CPP
    | "CPP"      -> L_CPP
    | "CALCULUS" -> L_CALC
    | "CALC"     -> L_CALC
    | "M3"       -> L_M3
    | "SQL"      -> L_SQL  (* Translates DBT-SQL + sources -> SQL w/ Inserts *)
    | "NONE"     -> L_NONE (* Used for getting just debug output *)
    | "DEBUG"    -> L_NONE
    | _          -> (give_up ("Unknown output language '"^a^"'"));;

let output_file = match flag_val "OUTPUT" with
  | None      -> stdout
  | Some("-") -> stdout
  | Some(f)   -> (open_out f);;

Debug.exec "ARGS" (fun () -> 
  StringMap.iter (fun k v ->
    print_line (k^":");
    List.iter (fun o -> 
      print_line ("   "^o)
    ) v
  ) arguments
);;

(********* TRANSLATE SQL TO RELCALC *********)

let sql_file_to_calc f =
  let lexbuff = Lexing.from_channel (if f <> "-" then (open_in f) else stdin) in
  Sqlparser.dbtoasterSqlList Sqllexer.tokenize lexbuff;;

Debug.exec "PARSE" (fun () -> Parsing.set_trace true);;

let (queries, sources) = 
  let (queries, sources) = 
    List.split (List.map sql_file_to_calc input_files)
  in (List.flatten queries, List.flatten sources);;

let query_list_to_calc_string qlist = 
  List.fold_left 
    (fun accum (query_exprs,_,_) ->
      accum^(List.fold_left (fun in_accum calc_term ->
        in_accum^(Calculus.term_as_string (Calculus.make_term calc_term))^"\n"
      ) "" query_exprs)
    ) "" qlist;;

Debug.print "CALCULUS" (fun () -> (query_list_to_calc_string queries));;

if language == L_CALC then
  (
    output_string output_file (query_list_to_calc_string queries);
    exit 0
  )
else ();;

(********* PRODUCE SQL FOR COMPARISON *********)

if language == L_SQL then
  (
    failwith "Translation to normal SQL unsupported at the moment";
  )
else ();;

(********* TRANSLATE RELCALC TO M3 *********)

let toplevel_queries = ref []

let calc_into_m3_inprogress qname (qlist,dbschema,qvars) m3ip = 
  fst
    (List.fold_left (fun (accum,sub_id) q ->
      (try 
        let subq_name = (qname^"_"^(string_of_int sub_id)) in
        (
          toplevel_queries := !toplevel_queries @ [subq_name];
          Compiler.compile Calculus.ModeOpenDomain
                           dbschema
                           (Calculus.make_term q,
                            Calculus.map_term 
                              (qname^"_"^(string_of_int sub_id))
                              qvars
                           )
                           CalcToM3.M3InProgress.generate_m3
                           accum
        )
      with 
        |Util.Function.NonFunctionalMappingException -> 
            Printexc.print_backtrace stdout; give_up "Error!"
      ), sub_id+1 ) (m3ip,1) qlist
    )

let m3_prog = 
  let (m3_prog_in_prog,_) = 
    List.fold_left (fun (accum,id) q ->
      (calc_into_m3_inprogress ("QUERY_"^(string_of_int id)) q accum, id + 1)
    ) (CalcToM3.M3InProgress.init, 1) queries
  in
    CalcToM3.M3InProgress.finalize m3_prog_in_prog;;

Debug.print "M3" (fun () -> (M3Common.pretty_print_prog m3_prog));;

(********* TRANSLATE M3 TO [language of your choosing] *********)

module M3OCamlCompiler = M3Compiler.Make(M3OCamlgen.CG);;

let compile_function: (M3.prog_t * M3.relation_input_t list -> string list -> 
                       Util.GenericIO.out_t -> unit) = 
  match language with
  | L_OCAML -> M3OCamlCompiler.compile_query
  | L_CPP   -> give_up "Compilation to C++ not implemented yet"
  | L_M3    -> (fun (p, s) tlq f -> 
      GenericIO.write f (fun fd -> 
          output_string fd (M3Common.pretty_print_prog p)))
  | L_NONE  -> (fun q tlq f -> ())
  | _       -> failwith "Error: Asked to output unknown language"
    (* Calc should have been outputted before M3 generation *)
;;

let compile = compile_function (m3_prog, sources) !toplevel_queries;;

if (not (flag_bool "COMPILE")) || (flag_bool "OUTPUT") then
  (* If we've gotten a -c but no -o, don't output the intermediaries *)
  compile (GenericIO.O_FileDescriptor(output_file))
else ();;

(********* COMPILE [language of your choosing] *********)

let compile_ocaml in_file_name =
  let ocaml_cc = "ocamlc" in
  let ocaml_lib_ext = ".cma" in
  let dbt_lib_ext = ".ml" in
  let ocaml_libs = [ "unix"; "str" ] in
  let dbt_lib_path = Filename.dirname (flag_val_force "$0") in
  let dbt_includes = [ "lib/ocaml" ] in
  let dbt_libs = [ "Util";
                   "M3";
                   "M3Common";
                   "lib/ocaml/SliceableMap";
                   "lib/ocaml/M3OCaml";
                   "lib/ocaml/StandardAdaptors" ] in
    (* would nice to generate args dynamically off the makefile *)
    Unix.execvp ocaml_cc 
      ( Array.of_list (
        [ ocaml_cc; "-ccopt"; "-O3" ] @
        (if Debug.active "COMPILE-WITH-GDB" then [ "-g" ] else []) @
        (List.flatten (List.map (fun x -> [ "-I" ; x ]) dbt_includes)) @
        (List.map (fun x -> x^ocaml_lib_ext) ocaml_libs) @
        (List.map (fun x -> dbt_lib_path^"/"^x^dbt_lib_ext) dbt_libs) @
        ["-" ; in_file_name ; "-o" ; (flag_val_force "COMPILE") ]
      ));;
  
let compile_ocaml_via_tmp () =
  compile (GenericIO.O_TempFile("dbtoaster_", ".ml", compile_ocaml));;

if flag_bool "COMPILE" then
  match language with
  | L_OCAML ->  
    (
      match (flag_val "OUTPUT") with
        | None      -> compile_ocaml_via_tmp ()
        | Some("-") -> compile_ocaml_via_tmp ()
        | Some(a)   -> compile_ocaml a
    )
  | L_CPP   -> give_up "Compilation of C++ not implemented yet"
  | _       -> give_up "No external compiler available for this language"
else ()