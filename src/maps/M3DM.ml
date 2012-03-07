open Ring
open Arithmetic
open Types
open Calculus
open Plan
open M3

type dm_prog_t = trigger_t list ref

let get_map_output_domain (expr: Calculus.expr_t): Calculus.expr_t =
    let target_leaf = 
            begin match expr with
            | CalcRing.Val(x) -> x
            | _ -> failwith "Expression should be leaf!"
            end in
        begin match target_leaf with
        | External(ename,eins,eouts,etype,emeta) ->
            CalcRing.Val(Rel(ename^"_output",eouts,etype))
        | _ -> failwith "Expression should be map!"
        end
        
let get_map_input_domain (expr: Calculus.expr_t): Calculus.expr_t =
    let target_leaf = 
            begin match expr with
            | CalcRing.Val(x) -> x
            | _ -> failwith "Expression should be leaf!"
            end in
        begin match target_leaf with
        | External(ename,eins,eouts,etype,emeta) ->
            CalcRing.Val(Rel(ename^"_input",eins,etype))
        | _ -> failwith "Expression should be map!"
        end
        
let get_singleton_tuple (relation: Schema.rel_t): Calculus.expr_t =
    let (rname, rvars, _, rtype) = relation in
        CalcRing.Val(Rel(rname^"_singleton", rvars, rtype))
        
let get_relation_vars (expr: Calculus.expr_t): var_t list = 
    let leaf = 
            begin match expr with
            | CalcRing.Val(x) -> x
            | _ -> failwith "Expression should be leaf!"
            end in
        begin match leaf with
        | Rel(_, rvars, _) ->
            rvars
        | _ -> failwith "Expression should be relation!"
        end
        
let simplify_dm_trigger (trigger: Plan.stmt_t): Plan.stmt_t list = 
    let left_domain = trigger.target_map in
(*    let update_domain = trigger.update_expr in *)
    let schema_left_domain = snd (Calculus.schema_of_expr left_domain) in
    if schema_left_domain = [] then [] else
    begin
        [trigger]
    end

let simplify_dm_triggers (trigger_list: Plan.stmt_t list): Plan.stmt_t list = 
    List.fold_left (fun (x) (y) -> x@(simplify_dm_trigger y)) [] trigger_list
    
        
let mk_dm_trigger (left_domain: Calculus.expr_t)
                (update_domain: Calculus.expr_t):Plan.stmt_t= 
    {
        target_map = left_domain;
        update_type = Plan.UpdateStmt;
        update_expr = update_domain
    }

let rec maintain (context: Calculus.expr_t)
                (formula: Calculus.expr_t) : Plan.stmt_t list * Calculus.expr_t =
    begin match formula with
    | CalcRing.Sum([q1;q2]) -> 
        let (trlist1, context1) = maintain(context)(q1) in
            let (trlist2, context2) = maintain(context)(q2) in 
                (trlist1 @ trlist2, CalcRing.mk_sum([context1; context2]))
    | CalcRing.Sum(q1::qo) -> 
        let (trlist1, context1) = maintain(context)(q1) in
            let (trlist2, context2) = maintain(context)(CalcRing.mk_sum qo) in 
                (trlist1 @ trlist2, CalcRing.mk_sum([context1; context2]))
    | CalcRing.Prod([q1;q2]) -> 
        let (trlist1, context1) = maintain(context)(q1) in
            let (trlist2, context2) = maintain(context1)(q2) in 
                (trlist1 @ trlist2, context2)
    | CalcRing.Prod(q1::qo) -> 
        let (trlist1, context1) = maintain(context)(q1) in
            let (trlist2, context2) = maintain(context1)(CalcRing.mk_prod qo) in 
                (trlist1 @ trlist2, context2)
    | CalcRing.Neg(q1) ->
        maintain(context)(q1)
    | CalcRing.Val(leaf) ->
        begin match leaf with
        | Value(v) -> ([], context)
        | External(ename,eins,eouts,etype,emeta) ->
            let input_domain = get_map_input_domain (formula) in
            let output_domain = get_map_output_domain (formula) in
            let input_vars = get_relation_vars input_domain in
            let context1 = CalcRing.mk_prod ([context; output_domain]) in
            let update_domain = CalcRing.Val(AggSum(input_vars, context))  in
            let dm_statement = mk_dm_trigger (input_domain) (update_domain) in
                ([dm_statement], context1)
        | AggSum(gb_vars, subexp) -> 
            let (trlist, context1) = maintain (context) (subexp) in
                let right_context = CalcRing.Val(AggSum(gb_vars, context1)) in
                    (trlist, CalcRing.mk_prod ([context; right_context]))
        | Rel(rname, rvars, _)    -> 
            ([], CalcRing.mk_prod ([context; formula]))
        | Cmp(op,subexp1,subexp2) -> 
            failwith ("comparison not supported!") (*TODO*)
        | Lift(target, subexp)    -> 
            let (trlist, context1) = maintain(context)(subexp) in
                (trlist, context1) (*FIXME*)
        end
    | _ -> failwith ("Incorrect formula")
    end

let maintain_statement (statement:Plan.stmt_t)
                        (relation: Schema.rel_t):Plan.stmt_t list = 
    let singleton_tuple = get_singleton_tuple (relation) in
    let left_input_domain = get_map_input_domain (statement.target_map) in
    let left_output_domain = get_map_output_domain (statement.target_map) in
    let left_output_vars = get_relation_vars left_output_domain in
    let (trigger_list, update_domain) = 
        let context = CalcRing.mk_prod ([singleton_tuple; left_input_domain]) in
        let (trigger_list, query_domain) = maintain (context) (statement.update_expr) in
         (trigger_list, CalcRing.Val(AggSum(left_output_vars, query_domain)) ) in
    let dm_statement = mk_dm_trigger (left_output_domain) (update_domain) in
        dm_statement :: trigger_list


let maintain_all (relation: Schema.rel_t)
                (stmts: Plan.stmt_t list)
                (event_type: Schema.event_type_t): trigger_t = 
    let dm_statements = ref [] in
    let dm_trigger: trigger_t = {event = (event_type, relation); statements = dm_statements} in
    List.iter (fun (statement:Plan.stmt_t) ->
            let dm_statement = maintain_statement (statement) (relation) in
            dm_statements := dm_statement @ !dm_statements
        ) stmts;
        dm_statements := simplify_dm_triggers !dm_statements;
    dm_trigger


let make_DM_triggers (m3_triggers: trigger_t list): dm_prog_t =
    let dm_triggers = ref [] in
    let dm_prog:dm_prog_t = dm_triggers in
        List.iter (fun (trigger:trigger_t) ->
            let (event_type, relation) = trigger.event in
            let dm_trigger = maintain_all (relation) (!(trigger.statements)) (event_type) in
            dm_triggers := dm_trigger :: !dm_triggers
        ) m3_triggers;
    dm_prog


let string_of_m3DM (prog:dm_prog_t): string = 
   "------------------- DM TRIGGERS --------------------\n"^
   (ListExtras.string_of_list ~sep:"\n\n" string_of_trigger !prog)