(** Values.
  A module implementing categories of basic values used in compiled programs.
  Currently these categories are:
   - ConstTValue: M3.const_t
   - FloatValue: float
   - K3Value: floats, ints, tuples, list + map collections
 
  Description of module usage:
   - variables are bound to values.
   - maps are keyed by values.
   - databases store values.
   - interpreted code yields values.
 *)

open Types

module type Value =
sig
    type t
    val zero : t
    val zero_of_type : type_t -> t
    val compare : t -> t -> int
    val to_string : t -> string
end

module type Valuation = functor (V : Value) ->
sig
   type key = string
   type value_t = V.t
   type t 
   
   val make : string list -> V.t list -> t
   val vars : t -> string list
   val bound : string -> t -> bool
   val value : string -> t -> V.t
   
   val consistent : t -> t -> bool
   val add : t -> string -> V.t -> t
   val bind : t -> (string * string) list -> t
   val extend : t -> t -> string list -> t
   val apply : t -> key list -> V.t list
   val to_string : t -> string
end


module AbstractValuation : Valuation = functor(V : Value) ->
struct
   (* the keys are variable names *)
   (**/**)
   module StringMap = Map.Make (String)
   (**/**)

   type key = StringMap.key
   type value_t = V.t
   type t = V.t StringMap.t

   (* Note: ordered result *)
   let make vars values  =
      List.fold_left (fun acc (k,v) -> StringMap.add k v acc)
         StringMap.empty (List.combine vars values)

   let to_string theta : string =
      StringMap.fold (fun k v acc -> acc^(if acc = "" then "" else " ")^
         k^"->"^(V.to_string v)) theta ""

   (* Note: ordered result *)
   let to_list m = StringMap.fold (fun s n l -> (s,n)::l) m []

   let vars theta = StringMap.fold (fun k _ acc -> k::acc) theta []

   let bound var theta = StringMap.mem var theta
   
   let value var theta = StringMap.find var theta

   let consistent theta1 theta2 =
      List.for_all (fun (k,v) ->
        (not(StringMap.mem k theta2)) || ((StringMap.find k theta2) = v))
        (to_list theta1)

   (* adds a single binding *)
   let add theta var value = StringMap.add var value theta

   (* extends m with the given bindings, which rename existing valuations *)
   let bind theta bindings =
      List.fold_left (fun acc (decl,def) ->
         StringMap.add decl (value def acc) acc) theta bindings

   (* extends m1 by given vars from m2.
    * assumes that m1 and m2 are consistent. *)
   (* Note: ordered result *)
   let extend theta1 theta2 ext =
      List.fold_left (fun acc k ->
        StringMap.add k (value k theta2) acc) theta1 ext

   let apply theta l = List.map (fun x ->
      try StringMap.find x theta
      with Not_found ->
        failwith ("No valuation for "^x^" in "^(to_string theta))) l

end

(* TODO: replace usage of ConstTValue with FloatValue to remove boxing from
 * generated code *)
module FloatValue : Value with type t = float =
struct
    type t = float
    let zero = 0.0
    let zero_of_type zt =  0.0
    let compare = Pervasives.compare
    let to_string = string_of_float
end

module ConstTValue : Value with type t = const_t =
struct
    type t = const_t
    let zero = CFloat(0.0)
    let zero_of_type = Types.zero_of_type
    let compare = Pervasives.compare
    let to_string = Types.string_of_const
end

(* Simplified K3 value *)
module rec SimpleK3Value :
sig
  type t =
    | Unit
    | Float          of float
    | Int            of int
    | Tuple          of t list
    | Fun            of (t -> t) 
    | ListCollection of t list

    val zero : t
    val zero_of_type : type_t -> t
    val compare : t -> t -> int
    val to_string : t -> string
end =
struct
  type t =
    | Unit
    | Float          of float
    | Int            of int
    | Tuple          of t list
    | Fun            of (t -> t) 
    | ListCollection of t list
  
  let zero = Float(0.0)
  let zero_of_type zt = begin match zt with
	| TInt -> Int(0)
	| TFloat -> Float(0.0)
	| _ -> failwith "Invalid type for zero_of_type"
  end
  let compare = Pervasives.compare

  let rec string_of_value v =
    begin match v with
    | Unit -> "unit"
    | Float(f) -> string_of_float f
    | Int(i) -> string_of_int i
    | Tuple(fl) -> "("^(String.concat "," (List.map string_of_value fl))^")"
    | Fun(f) -> "<fun>"
    | ListCollection(vl) ->
      "ListCollection("^(String.concat ","
        (List.map string_of_value vl))^")"
    end
    
  let to_string = string_of_value
end
and K3SValuationMap : SliceableMap.S with type key_elt = SimpleK3Value.t
    = SliceableMap.Make(SimpleK3Value)

module K3SValuation = AbstractValuation(SimpleK3Value)


(* K3 values, includes base types, unit, tuples and several types of collections,
 * including named simple lists, such as FloatList and TupleList, whose contents
 * are always flat elements, 1- and 2-level persistent collections
 * (SingleMap, DoubleMap), as well as arbitrarily nested collections, namely
 * ListCollection and an indexed MapCollection.
 *
 * Note explictly defined type, which is a subtype of both Value above, and
 * Database.SliceableInOutMap. This is necessary since values include variants
 * that are single and double maps. *)
module rec K3Value :
sig
    type single_map_t = t K3ValuationMap.t
    and map_t = single_map_t K3ValuationMap.t
    and t = 
    | Unit
    | BaseValue      of Types.const_t
    | Tuple          of t list
    | Fun            of (t -> t) 

    (* Persistent collection values, these are yielded on accessing
     * the persistent store. *)
    | SingleMap      of single_map_t
    | DoubleMap      of map_t

    (* Core internal collections used during processing.
     * -- these are flat collections, i.e. value_t is expected to
     *    be a base type, such as float/int for FloatLists, and
     *    tuple(float/int) for TupleLists
     * -- SingleMaps and DoubleMaps are converted to these internal types
     *    by tuple collection accessors (mem/lookup/slice) *)
    | FloatList      of t list (* float list *)
    | TupleList      of t list (* float list list *)
    
   (* In some cases, we'll have empty lists.  Due to the lack of strict typing, 
      it's sometimes possible for the code to be unable to figure out what the
      list's type is if it has no content.  Thus, we have an empty list type.
      This type is happy to merge/connect with/do anything with any other type
      of list, since it's empty *)
    | EmptyList
     
    (* slicing a double map yields a SingleMapList of key * smap entries *)
    | SingleMapList  of (t list * single_map_t) list

    (* Arbitrarily nested collection based on lists *)
    | ListCollection     of t list

    (* Arbitrarily nested collections of tuples *)
    | MapCollection      of t K3ValuationMap.t

    module Map : SliceableMap.S
       with type key_elt = t and
            type 'a t = 'a K3ValuationMap.t

    val zero : t
    val zero_of_type : type_t -> t
    val compare : t -> t -> int
    val string_of_value : t -> string
    val string_of_smap : ?sep:string -> single_map_t -> string
    val string_of_map : ?sep:string -> map_t -> string
    val to_string : t -> string
end =
struct
    module Map = K3ValuationMap
    type single_map_t = t K3ValuationMap.t
    and map_t = single_map_t K3ValuationMap.t
    and t = 
    | Unit
    | BaseValue      of Types.const_t
    | Tuple          of t list
    | Fun            of (t -> t) 
    | SingleMap      of single_map_t
    | DoubleMap      of map_t
    | FloatList      of t list
    | TupleList      of t list
    | EmptyList
    | SingleMapList  of (t list * single_map_t) list
    | ListCollection of t list
    | MapCollection  of t K3ValuationMap.t

    let zero = BaseValue(CFloat(0.0))
	 let zero_of_type zt = BaseValue(Types.zero_of_type zt)
	 let compare = Pervasives.compare

    let rec key_to_string k = ListExtras.ocaml_of_list string_of_value k
    and string_of_vmap ?(sep = ";\n") sm   = K3ValuationMap.to_string ~sep:sep key_to_string string_of_value sm
    and string_of_smap ?(sep = ";\n") sm   = string_of_vmap ~sep:sep sm 
    and string_of_map  ?(sep = ";\n") m    = K3ValuationMap.to_string ~sep:sep key_to_string string_of_smap m 

    and string_of_value v =
      begin match v with
      | Unit -> "unit"
      | BaseValue(c) -> string_of_const c
      | Tuple(fl) -> "("^(String.concat "," (List.map string_of_value fl))^")"
      | Fun(f) -> "<fun>"

      | SingleMap(sm) -> "SingleMap("^(string_of_smap sm)^")"
      | DoubleMap(dm) -> "DoubleMap("^(string_of_map dm)^")"

      | FloatList(fl) ->
          "["^(String.concat ";" (List.map string_of_value fl))^"]"
      
      | TupleList(kvl) ->
          "["^(String.concat ";" (List.map string_of_value kvl))^"]"

      | SingleMapList(sml) ->
          ("["^(List.fold_left (fun acc (k,m) ->
                (if acc = "" then "" else acc^";")^
                (string_of_value (Tuple k))^","^
                (string_of_value (SingleMap m)))
               "" sml)^"]")
      | EmptyList -> "EmptyList[]"
      | ListCollection(vl) -> "ListCollection("^(String.concat ","
                            (List.map string_of_value vl))^")"

      | MapCollection(m) -> "MapCollection("^(string_of_vmap m)^")"
      end

    let to_string = string_of_value
end
and K3ValuationMap : SliceableMap.S with type key_elt = K3Value.t
    = SliceableMap.Make(K3Value)


(* K3 Valuations allow variables to be bound to any K3 value, e.g.
 * collections, tuples, etc. *)
module K3Valuation = AbstractValuation(K3Value)
