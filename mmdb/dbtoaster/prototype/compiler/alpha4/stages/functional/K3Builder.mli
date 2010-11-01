open K3.SR

(* Construction from M3 *)
val calc_to_singleton_expr : M3.Prepared.calc_t -> expr_t

val op_to_expr :
    (M3.var_t list -> expr_t -> expr_t -> expr_t) ->
    M3.Prepared.calc_t -> M3.Prepared.calc_t -> M3.Prepared.calc_t -> expr_t

val calc_to_expr : M3.Prepared.calc_t -> expr_t
val m3rhs_to_expr : M3.var_t list -> M3.Prepared.aggecalc_t -> expr_t

(* Incremental section *)
val collection_stmt : M3.var_t list -> M3.Prepared.stmt_t -> statement
val collection_trig : M3.Prepared.trig_t -> trigger
val collection_prog :
    M3.Prepared.prog_t -> M3Common.Patterns.pattern_map -> program
