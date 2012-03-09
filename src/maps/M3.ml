(** 
   The fourth representation in the calculus compiler pipeline
   (SQL -> Calc -> Plan -> M3). 
   
   An M3 program is a reshuffling of the triggers in a Plan, so that they're 
   organized by triggering event.  This is stored in addition to some user-
   defined metadata:
      -  A set of named queries that define what the user is interested in.
      -  A set of datastructures that will be used in the course of executing
         queries and triggers.
      -  The triggers themselves
      -  The schema of the database
*)

open Ring
open Arithmetic
open Types
open Calculus
open Plan

type trigger_t = {
   event      : Schema.event_t;
   statements : Plan.stmt_t list ref
}

type map_t = 
   | DSView  of Plan.ds_t
   | DSTable of Schema.rel_t

type prog_t = {

   (** Queries that the API of the datastructure that we are creating.  Mostly
      these will just be a lookup of one or more datastructures.  For debugging
      binaries generated by DBToaster, these queries will be executed at the
      end of compilation to produce the output *)
   queries   : (string * expr_t) list ref;
   
   (** The set of datastructures (Maps) that we store.  These include:
      Views: Mutable datastructures representing the result of a query.  Views
             may appear on the left-hand side of a trigger statement, and are
             referenced in queries using 'External[...][...]'
      Tables: Immutable datastructures loaded in at the start of processing.
              Tables may not be updated once processing has started, and are
              referenced in queries using Rel(...) *)
   maps      : map_t list ref;
   
   (** Triggers for each event that can be handled by this program.  These
      use event times as defined in Schema, and statements (as defined in Plan)
      of the form External[...][...] (:= OR +=) CalculusExpression.  When the
      triggerring event occurs, the specified CalculusExpression will be 
      evaluated (with the trigger's parameters in-scope), and used to update the
      specified view (which again, is sliced with the trigger's parameters in-
      scope).  
      
      The calculus expression may only contain Rel(...) terms referencing 
      TableRels.
      
      Every possible trigger that can occur in this program *must* be defined,
      even if it has no accompanying statements.  This means both an Insert
      and a Delete trigger for every StreamRel.
      *)
   triggers  : trigger_t list ref;

   (** The schema of the overall database.  
      Restriction: For each StreamRel in the db schema, there must be insert
      and delete triggers.  For each TableRel in the db schema, there must be
      a corresponding DSTable() in maps. *)
   db        : Schema.t
}

(************************* Stringifiers *************************)

let string_of_map ?(is_query=false) (map:map_t): string = begin match map with
   | DSView(view) -> 
      "DECLARE "^
      (if is_query then "QUERY " else "")^
      "MAP "^(Calculus.string_of_expr (
         Calculus.strip_calc_metadata view.ds_name))^
      " := \n    "^
      (Calculus.string_of_expr view.ds_definition)^";"
   | DSTable(rel) -> Schema.code_of_rel rel
   end

let string_of_trigger (trigger:trigger_t): string = 
   (Schema.string_of_event trigger.event)^" {"^
   (ListExtras.string_of_list ~sep:"" (fun stmt ->
      "\n   "^(Plan.string_of_statement stmt)^";"
   ) !(trigger.statements))^"\n}"

let string_of_m3 (prog:prog_t): string = 
   "-------------------- SOURCES --------------------\n"^
   (Schema.code_of_schema prog.db)^"\n\n"^
   "--------------------- MAPS ----------------------\n"^
   (* Skip Table maps -- these are already printed above in the schema *)
   (ListExtras.string_of_list ~sep:"\n\n" string_of_map (List.filter (fun x ->
      match x with DSTable(_) -> false | _ -> true) !(prog.maps)))^"\n\n"^
   "-------------------- QUERIES --------------------\n"^
   (ListExtras.string_of_list ~sep:"\n\n" (fun (qname,qdefn) ->
      "DECLARE QUERY "^qname^" := "^(Calculus.string_of_expr qdefn)^";"
   ) !(prog.queries))^"\n\n"^
   "------------------- TRIGGERS --------------------\n"^
   (ListExtras.string_of_list ~sep:"\n\n" string_of_trigger !(prog.triggers))


(************************* Accessors/Mutators *************************)

let get_trigger (prog:prog_t) 
                (event:Schema.event_t): trigger_t =
   List.find (fun trig -> Schema.events_equal event trig.event) !(prog.triggers)
;;

let get_triggers (prog:prog_t) : trigger_t list =
    !(prog.triggers)
;;

let add_rel (prog:prog_t) ?(source = Schema.NoSource)
                          ?(adaptor = ("", []))
                          (rel:Schema.rel_t): unit = 
   Schema.add_rel prog.db ~source:source ~adaptor:adaptor rel;
   let (_,_,t,_) = rel in if t = Schema.TableRel then
      prog.maps     := (DSTable(rel)) :: !(prog.maps)
   else
      prog.triggers := { event = (Schema.InsertEvent(rel)); statements=ref [] }
                    :: { event = (Schema.DeleteEvent(rel)); statements=ref [] }
                    :: !(prog.triggers)
;;

let add_query (prog:prog_t) (name:string) (expr:expr_t): unit =
   prog.queries := (name, expr) :: !(prog.queries)
;;

let add_view (prog:prog_t) (view:Plan.ds_t): unit =
   prog.maps := (DSView(view)) :: !(prog.maps)
;;

let add_stmt (prog:prog_t) (event:Schema.event_t)
                           (stmt:stmt_t): unit =
   let (relv) = Schema.event_vars event in
   try
      let trigger = get_trigger prog event in
      let trig_relv = Schema.event_vars trigger.event in
      (* We need to ensure that we're not clobbering any existing variable names
         with these rewrites.  This includes not just the update expression, 
         but also any IVC computations present in the target map reference *)
      let safe_mapping = 
         (find_safe_var_mapping 
            (find_safe_var_mapping 
               (List.combine relv trig_relv) 
               stmt.update_expr)
            stmt.target_map)
      in
      trigger.statements := !(trigger.statements) @ [{
         target_map = rename_vars safe_mapping stmt.target_map;
         update_type = stmt.update_type;
         update_expr  = rename_vars safe_mapping stmt.update_expr
      }]
   with Not_found -> 
      failwith "Adding statement for an event that has not been established"
;;
(************************* Metadata *************************)


(************************* Initializers *************************)

let default_triggers () = 
   List.map (fun x -> { event = x; statements = ref [] })
   [  Schema.SystemInitializedEvent;
   ];;

let init (db:Schema.t): prog_t = 
   let (db_tables, db_streams) = 
      List.partition (fun (_,_,t,_) -> t = Schema.TableRel)
                     (Schema.rels db)
   in
   {  queries = ref [];
      maps    = ref (List.map (fun x -> DSTable(x)) db_tables);
      triggers = 
         ref ((List.map (fun x -> { event = x; statements = ref [] })
                       (List.flatten 
                          (List.map (fun x -> 
                                       [  Schema.InsertEvent(x); 
                                          Schema.DeleteEvent(x)])
                                    db_streams))) @
               (default_triggers ()));
      db = db
   }
;;

let empty_prog (): prog_t = 
   {  queries = ref []; maps = ref []; triggers = ref (default_triggers ()); 
      db = Schema.empty_db () }
;;

let plan_to_m3 (db:Schema.t) (plan:Plan.plan_t):prog_t =
   let prog = init db in
      List.iter (fun (ds:Plan.compiled_ds_t) ->
         add_view prog ds.description;
         List.iter (fun (event, stmt) ->
            add_stmt prog event stmt
         ) (ds.ds_triggers)
      ) plan;
   prog
;;

