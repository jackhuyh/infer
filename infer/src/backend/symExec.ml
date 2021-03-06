(*
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

(** Symbolic Execution *)

module L = Logging
module F = Format

let rec fldlist_assoc fld = function
  | [] -> raise Not_found
  | (fld', x, _):: l -> if Ident.fieldname_equal fld fld' then x else fldlist_assoc fld l

let rec unroll_type tenv typ off =
  match (typ, off) with
  | Typ.Tvar _, _ ->
      let typ' = Tenv.expand_type tenv typ in
      unroll_type tenv typ' off
  | Typ.Tstruct { Typ.instance_fields; static_fields }, Sil.Off_fld (fld, _) ->
      begin
        try fldlist_assoc fld (instance_fields @ static_fields)
        with Not_found ->
          L.d_strln ".... Invalid Field Access ....";
          L.d_strln ("Fld : " ^ Ident.fieldname_to_string fld);
          L.d_str "Type : "; Typ.d_full typ; L.d_ln ();
          raise (Exceptions.Bad_footprint __POS__)
      end
  | Typ.Tarray (typ', _), Sil.Off_index _ ->
      typ'
  | _, Sil.Off_index (Exp.Const (Const.Cint i)) when IntLit.iszero i ->
      typ
  | _ ->
      L.d_strln ".... Invalid Field Access ....";
      L.d_str "Fld : "; Sil.d_offset off; L.d_ln ();
      L.d_str "Type : "; Typ.d_full typ; L.d_ln ();
      assert false

(** Given a node, returns a list of pvar of blocks that have been nullified in the block. *)
let get_blocks_nullified node =
  let null_blocks = IList.flatten(IList.map (fun i -> match i with
      | Sil.Nullify(pvar, _) when Sil.is_block_pvar pvar -> [pvar]
      | _ -> []) (Cfg.Node.get_instrs node)) in
  null_blocks

(** Given a proposition and an objc block checks whether by existentially quantifying
    captured variables in the block we obtain a leak. *)
let check_block_retain_cycle tenv caller_pname prop block_nullified =
  let mblock = Pvar.get_name block_nullified in
  let block_pname = Procname.mangled_objc_block (Mangled.to_string mblock) in
  let block_captured =
    match AttributesTable.load_attributes block_pname with
    | Some attributes ->
        fst (IList.split attributes.ProcAttributes.captured)
    | None ->
        [] in
  let prop' = Cfg.remove_seed_captured_vars_block tenv block_captured prop in
  let prop'' = Prop.prop_rename_fav_with_existentials tenv prop' in
  let _ : Prop.normal Prop.t = Abs.abstract_junk ~original_prop: prop caller_pname tenv prop'' in
  ()

(** Apply function [f] to the expression at position [offlist] in [strexp].
    If not found, expand [strexp] and apply [f] to [None].
    The routine should maintain the invariant that strexp and typ correspond to
    each other exactly, without involving any re - interpretation of some type t
    as the t array. The [fp_root] parameter indicates whether the kind of the
    root expression of the corresponding pointsto predicate is a footprint identifier.
    The function can expand a list of higher - order [hpara_psto] predicates, if
    the list is stored at [offlist] in [strexp] initially. The expanded list
    is returned as a part of the result. All these happen under [p], so that it
    is sound to call the prover with [p]. Finally, before running this function,
    the tool should run strexp_extend_value in rearrange.ml for the same strexp
    and offlist, so that all the necessary extensions of strexp are done before
    this function. If the tool follows this protocol, it will never hit the assert
    false cases for field and array accesses. *)
let rec apply_offlist
    pdesc tenv p fp_root nullify_struct (root_lexp, strexp, typ) offlist
    (f: Exp.t option -> Exp.t) inst lookup_inst =
  let pname = Cfg.Procdesc.get_proc_name pdesc in
  let pp_error () =
    L.d_strln ".... Invalid Field ....";
    L.d_str "strexp : "; Sil.d_sexp strexp; L.d_ln ();
    L.d_str "offlist : "; Sil.d_offset_list offlist; L.d_ln ();
    L.d_str "type : "; Typ.d_full typ; L.d_ln ();
    L.d_str "prop : "; Prop.d_prop p; L.d_ln (); L.d_ln () in
  match offlist, strexp with
  | [], Sil.Eexp (e, inst_curr) ->
      let inst_is_uninitialized = function
        | Sil.Ialloc ->
            (* java allocation initializes with default values *)
            !Config.curr_language <> Config.Java
        | Sil.Iinitial -> true
        | _ -> false in
      let is_hidden_field () =
        match State.get_instr () with
        | Some (Sil.Load (_, Exp.Lfield (_, fieldname, _), _, _)) ->
            Ident.fieldname_is_hidden fieldname
        | _ -> false in
      let inst_new = match inst with
        | Sil.Ilookup when inst_is_uninitialized inst_curr && not (is_hidden_field()) ->
            (* we are in a lookup of an uninitialized value *)
            lookup_inst := Some inst_curr;
            let alloc_attribute_opt =
              if inst_curr = Sil.Iinitial then None
              else Attribute.get_undef tenv p root_lexp in
            let deref_str = Localise.deref_str_uninitialized alloc_attribute_opt in
            let err_desc = Errdesc.explain_memory_access tenv deref_str p (State.get_loc ()) in
            let exn = (Exceptions.Uninitialized_value (err_desc, __POS__)) in
            let pre_opt = State.get_normalized_pre (Abs.abstract_no_symop pname) in
            Reporting.log_warning pname ?pre:pre_opt exn;
            Sil.update_inst inst_curr inst
        | Sil.Ilookup -> (* a lookup does not change an inst unless it is inst_initial *)
            lookup_inst := Some inst_curr;
            inst_curr
        | _ -> Sil.update_inst inst_curr inst in
      let e' = f (Some e) in
      (e', Sil.Eexp (e', inst_new), typ, None)
  | [], Sil.Estruct (fesl, inst') ->
      if not nullify_struct then (f None, Sil.Estruct (fesl, inst'), typ, None)
      else if fp_root then (pp_error(); assert false)
      else
        begin
          L.d_strln "WARNING: struct assignment treated as nondeterministic assignment";
          (f None, Prop.create_strexp_of_type tenv Prop.Fld_init typ None inst, typ, None)
        end
  | [], Sil.Earray _ ->
      let offlist' = (Sil.Off_index Exp.zero):: offlist in
      apply_offlist
        pdesc tenv p fp_root nullify_struct (root_lexp, strexp, typ) offlist' f inst lookup_inst
  | (Sil.Off_fld _):: _, Sil.Earray _ ->
      let offlist_new = Sil.Off_index(Exp.zero) :: offlist in
      apply_offlist
        pdesc tenv p fp_root nullify_struct (root_lexp, strexp, typ) offlist_new f inst lookup_inst
  | (Sil.Off_fld (fld, fld_typ)):: offlist', Sil.Estruct (fsel, inst') ->
      begin
        let typ' = Tenv.expand_type tenv typ in
        let struct_typ =
          match typ' with
          | Typ.Tstruct struct_typ ->
              struct_typ
          | _ -> assert false in
        let t' = unroll_type tenv typ (Sil.Off_fld (fld, fld_typ)) in
        try
          let _, se' = IList.find (fun fse -> Ident.fieldname_equal fld (fst fse)) fsel in
          let res_e', res_se', res_t', res_pred_insts_op' =
            apply_offlist
              pdesc tenv p fp_root nullify_struct
              (root_lexp, se', t') offlist' f inst lookup_inst in
          let replace_fse fse =
            if Ident.fieldname_equal fld (fst fse) then (fld, res_se') else fse in
          let res_se = Sil.Estruct (IList.map replace_fse fsel, inst') in
          let replace_fta (f, t, a) =
            if Ident.fieldname_equal fld f then (fld, res_t', a) else (f, t, a) in
          let instance_fields' = IList.map replace_fta struct_typ.Typ.instance_fields in
          let res_t =
            Typ.Tstruct { struct_typ with Typ.instance_fields = instance_fields' } in
          (res_e', res_se, res_t, res_pred_insts_op')
        with Not_found ->
          pp_error();
          assert false
          (* This case should not happen. The rearrangement should
             have materialized all the accessed cells. *)
      end
  | (Sil.Off_fld _):: _, _ ->
      pp_error();
      assert false

  | (Sil.Off_index idx) :: offlist', Sil.Earray (len, esel, inst1) ->
      let nidx = Prop.exp_normalize_prop tenv p idx in
      begin
        let typ' = Tenv.expand_type tenv typ in
        let t', len' = match typ' with Typ.Tarray (t', len') -> (t', len') | _ -> assert false in
        try
          let idx_ese', se' = IList.find (fun ese -> Prover.check_equal tenv p nidx (fst ese)) esel in
          let res_e', res_se', res_t', res_pred_insts_op' =
            apply_offlist
              pdesc tenv p fp_root nullify_struct
              (root_lexp, se', t') offlist' f inst lookup_inst in
          let replace_ese ese =
            if Exp.equal idx_ese' (fst ese)
            then (idx_ese', res_se')
            else ese in
          let res_se = Sil.Earray (len, IList.map replace_ese esel, inst1) in
          let res_t = Typ.Tarray (res_t', len') in
          (res_e', res_se, res_t, res_pred_insts_op')
        with Not_found ->
          (* return a nondeterministic value if the index is not found after rearrangement *)
          L.d_str "apply_offlist: index "; Sil.d_exp idx;
          L.d_strln " not materialized -- returning nondeterministic value";
          let res_e' = Exp.Var (Ident.create_fresh Ident.kprimed) in
          (res_e', strexp, typ, None)
      end
  | (Sil.Off_index _):: _, _ ->
      pp_error();
      raise (Exceptions.Internal_error (Localise.verbatim_desc "Array out of bounds in Symexec"))
(* This case should not happen. The rearrangement should
   have materialized all the accessed cells. *)

(** Given [lexp |-> se: typ], if the location [offlist] exists in [se],
    function [ptsto_lookup p (lexp, se, typ) offlist id] returns a tuple.
    The first component of the tuple is an expression at position [offlist] in [se].
    The second component is an expansion of the predicate [lexp |-> se: typ],
    where the entity at [offlist] in [se] is expanded if the entity is a list of
    higher - order parameters [hpara_psto]. If this expansion happens,
    the last component of the tuple is a list of pi - sigma pairs obtained
    by instantiating the [hpara_psto] list. Otherwise, the last component is None.
    All these steps happen under [p]. So, we can call a prover with [p].
    Finally, before running this function, the tool should run strexp_extend_value
    in rearrange.ml for the same se and offlist, so that all the necessary
    extensions of se are done before this function. *)
let ptsto_lookup pdesc tenv p (lexp, se, typ, len, st) offlist id =
  let f =
    function Some exp -> exp | None -> Exp.Var id in
  let fp_root =
    match lexp with Exp.Var id -> Ident.is_footprint id | _ -> false in
  let lookup_inst = ref None in
  let e', se', typ', pred_insts_op' =
    apply_offlist
      pdesc tenv p fp_root false (lexp, se, typ) offlist f Sil.inst_lookup lookup_inst in
  let lookup_uninitialized = (* true if we have looked up an uninitialized value *)
    match !lookup_inst with
    | Some (Sil.Iinitial | Sil.Ialloc | Sil.Ilookup) -> true
    | _ -> false in
  let ptsto' = Prop.mk_ptsto tenv lexp se' (Exp.Sizeof (typ', len, st)) in
  (e', ptsto', pred_insts_op', lookup_uninitialized)

(** [ptsto_update p (lexp,se,typ) offlist exp] takes
    [lexp |-> se: typ], and updates [se] by replacing the
    expression at [offlist] with [exp]. Then, it returns
    the updated pointsto predicate. If [lexp |-> se: typ] gets
    expanded during this update, the generated pi - sigma list from
    the expansion gets returned, and otherwise, None is returned.
    All these happen under the proposition [p], so it is ok call
    prover with [p]. Finally, before running this function,
    the tool should run strexp_extend_value in rearrange.ml for the same
    se and offlist, so that all the necessary extensions of se are done
    before this function. *)
let ptsto_update pdesc tenv p (lexp, se, typ, len, st) offlist exp =
  let f _ = exp in
  let fp_root =
    match lexp with Exp.Var id -> Ident.is_footprint id | _ -> false in
  let lookup_inst = ref None in
  let _, se', typ', pred_insts_op' =
    let pos = State.get_path_pos () in
    apply_offlist
      pdesc tenv p fp_root true (lexp, se, typ) offlist f (State.get_inst_update pos) lookup_inst in
  let ptsto' = Prop.mk_ptsto tenv lexp se' (Exp.Sizeof (typ', len, st)) in
  (ptsto', pred_insts_op')

let update_iter iter pi sigma =
  let iter' = Prop.prop_iter_update_current_by_list iter sigma in
  IList.fold_left (Prop.prop_iter_add_atom false) iter' pi

(** Precondition: se should not include hpara_psto
    that could mean nonempty heaps. *)
let rec execute_nullify_se = function
  | Sil.Eexp _ ->
      Sil.Eexp (Exp.zero, Sil.inst_nullify)
  | Sil.Estruct (fsel, _) ->
      let fsel' = IList.map (fun (fld, se) -> (fld, execute_nullify_se se)) fsel in
      Sil.Estruct (fsel', Sil.inst_nullify)
  | Sil.Earray (len, esel, _) ->
      let esel' = IList.map (fun (idx, se) -> (idx, execute_nullify_se se)) esel in
      Sil.Earray (len, esel', Sil.inst_nullify)

(** Do pruning for conditional [if (e1 != e2) ] if [positive] is true
    and [(if (e1 == e2)] if [positive] is false *)
let prune_ne tenv ~positive e1 e2 prop =
  let is_inconsistent =
    if positive then Prover.check_equal tenv prop e1 e2
    else Prover.check_disequal tenv prop e1 e2 in
  if is_inconsistent then Propset.empty
  else
    let conjoin = if positive then Prop.conjoin_neq else Prop.conjoin_eq in
    let new_prop = conjoin tenv ~footprint: (!Config.footprint) e1 e2 prop in
    if Prover.check_inconsistency tenv new_prop then Propset.empty
    else Propset.singleton tenv new_prop

(** Do pruning for conditional "if ([e1] CMP [e2])" if [positive] is
    true and "if (!([e1] CMP [e2]))" if [positive] is false, where CMP
    is "<" if [is_strict] is true and "<=" if [is_strict] is false.
*)
let prune_ineq tenv ~is_strict ~positive prop e1 e2 =
  if Exp.equal e1 e2 then
    if (positive && not is_strict) || (not positive && is_strict) then
      Propset.singleton tenv prop
    else Propset.empty
  else
    (* build the pruning condition and its negation, as explained in
       the comment above *)
    (* build [e1] CMP [e2] *)
    let cmp = if is_strict then Binop.Lt else Binop.Le in
    let e1_cmp_e2 = Exp.BinOp (cmp, e1, e2) in
    (* build !([e1] CMP [e2]) *)
    let dual_cmp = if is_strict then Binop.Le else Binop.Lt in
    let not_e1_cmp_e2 = Exp.BinOp (dual_cmp, e2, e1) in
    (* take polarity into account *)
    let (prune_cond, not_prune_cond) =
      if positive then (e1_cmp_e2, not_e1_cmp_e2)
      else (not_e1_cmp_e2, e1_cmp_e2) in
    let is_inconsistent = Prover.check_atom tenv prop (Prop.mk_inequality tenv not_prune_cond) in
    if is_inconsistent then Propset.empty
    else
      let footprint = !Config.footprint in
      let prop_with_ineq = Prop.conjoin_eq tenv ~footprint prune_cond Exp.one prop in
      Propset.singleton tenv prop_with_ineq

let rec prune tenv ~positive condition prop =
  match condition with
  | Exp.Var _ | Exp.Lvar _ ->
      prune_ne tenv ~positive condition Exp.zero prop
  | Exp.Const (Const.Cint i) when IntLit.iszero i ->
      if positive then Propset.empty else Propset.singleton tenv prop
  | Exp.Const (Const.Cint _ | Const.Cstr _ | Const.Cclass _) | Exp.Sizeof _ ->
      if positive then Propset.singleton tenv prop else Propset.empty
  | Exp.Const _ ->
      assert false
  | Exp.Cast (_, condition') ->
      prune tenv ~positive condition' prop
  | Exp.UnOp (Unop.LNot, condition', _) ->
      prune tenv ~positive:(not positive) condition' prop
  | Exp.UnOp _ ->
      assert false
  | Exp.BinOp (Binop.Eq, e, Exp.Const (Const.Cint i))
  | Exp.BinOp (Binop.Eq, Exp.Const (Const.Cint i), e)
    when IntLit.iszero i && not (IntLit.isnull i) ->
      prune tenv ~positive:(not positive) e prop
  | Exp.BinOp (Binop.Eq, e1, e2) ->
      prune_ne tenv ~positive:(not positive) e1 e2 prop
  | Exp.BinOp (Binop.Ne, e, Exp.Const (Const.Cint i))
  | Exp.BinOp (Binop.Ne, Exp.Const (Const.Cint i), e)
    when IntLit.iszero i && not (IntLit.isnull i) ->
      prune tenv ~positive e prop
  | Exp.BinOp (Binop.Ne, e1, e2) ->
      prune_ne tenv ~positive e1 e2 prop
  | Exp.BinOp (Binop.Ge, e2, e1) | Exp.BinOp (Binop.Le, e1, e2) ->
      prune_ineq tenv ~is_strict:false ~positive prop e1 e2
  | Exp.BinOp (Binop.Gt, e2, e1) | Exp.BinOp (Binop.Lt, e1, e2) ->
      prune_ineq tenv ~is_strict:true ~positive prop e1 e2
  | Exp.BinOp (Binop.LAnd, condition1, condition2) ->
      let pruner = if positive then prune_inter tenv else prune_union tenv in
      pruner ~positive condition1 condition2 prop
  | Exp.BinOp (Binop.LOr, condition1, condition2) ->
      let pruner = if positive then prune_union tenv else prune_inter tenv in
      pruner ~positive condition1 condition2 prop
  | Exp.BinOp _ | Exp.Lfield _ | Exp.Lindex _ ->
      prune_ne tenv ~positive condition Exp.zero prop
  | Exp.Exn _ ->
      assert false
  | Exp.Closure _ ->
      assert false

and prune_inter tenv ~positive condition1 condition2 prop =
  let res = ref Propset.empty in
  let pset1 = prune tenv ~positive condition1 prop in
  let do_p p =
    res := Propset.union (prune tenv ~positive condition2 p) !res in
  Propset.iter do_p pset1;
  !res

and prune_union tenv ~positive condition1 condition2 prop =
  let pset1 = prune tenv ~positive condition1 prop in
  let pset2 = prune tenv ~positive condition2 prop in
  Propset.union pset1 pset2

let dangerous_functions =
  let dangerous_list = ["gets"] in
  ref ((IList.map Procname.from_string_c_fun) dangerous_list)

let check_inherently_dangerous_function caller_pname callee_pname =
  if IList.exists (Procname.equal callee_pname) !dangerous_functions then
    let exn =
      Exceptions.Inherently_dangerous_function
        (Localise.desc_inherently_dangerous_function callee_pname) in
    let pre_opt = State.get_normalized_pre (Abs.abstract_no_symop caller_pname) in
    Reporting.log_warning caller_pname ?pre:pre_opt exn

let proc_is_defined proc_name =
  match AttributesTable.load_attributes proc_name with
  | Some attributes ->
      attributes.ProcAttributes.is_defined
  | None ->
      false

let call_should_be_skipped callee_pname summary =
  (* check skip flag *)
  Specs.get_flag callee_pname proc_flag_skip <> None
  (* skip abstract methods *)
  || summary.Specs.attributes.ProcAttributes.is_abstract
  (* treat calls with no specs as skip functions in angelic mode *)
  || (Config.angelic_execution && Specs.get_specs_from_payload summary == [])

(** In case of constant string dereference, return the result immediately *)
let check_constant_string_dereference lexp =
  let string_lookup s n =
    let c = try Char.code (String.get s (IntLit.to_int n)) with Invalid_argument _ -> 0 in
    Exp.int (IntLit.of_int c) in
  match lexp with
  | Exp.BinOp(Binop.PlusPI, Exp.Const (Const.Cstr s), e)
  | Exp.Lindex (Exp.Const (Const.Cstr s), e) ->
      let value = match e with
        | Exp.Const (Const.Cint n)
          when IntLit.geq n IntLit.zero &&
               IntLit.leq n (IntLit.of_int (String.length s)) ->
            string_lookup s n
        | _ -> Exp.get_undefined false in
      Some value
  | Exp.Const (Const.Cstr s) ->
      Some (string_lookup s IntLit.zero)
  | _ -> None

(** Normalize an expression and check for arithmetic problems *)
let check_arith_norm_exp tenv pname exp prop =
  match Attribute.find_arithmetic_problem tenv (State.get_path_pos ()) prop exp with
  | Some (Attribute.Div0 div), prop' ->
      let desc = Errdesc.explain_divide_by_zero tenv div (State.get_node ()) (State.get_loc ()) in
      let exn = Exceptions.Divide_by_zero (desc, __POS__) in
      let pre_opt = State.get_normalized_pre (Abs.abstract_no_symop pname) in
      Reporting.log_warning pname ?pre:pre_opt exn;
      Prop.exp_normalize_prop tenv prop exp, prop'
  | Some (Attribute.UminusUnsigned (e, typ)), prop' ->
      let desc =
        Errdesc.explain_unary_minus_applied_to_unsigned_expression tenv
          e typ (State.get_node ()) (State.get_loc ()) in
      let exn = Exceptions.Unary_minus_applied_to_unsigned_expression (desc, __POS__) in
      let pre_opt = State.get_normalized_pre (Abs.abstract_no_symop pname) in
      Reporting.log_warning pname ?pre:pre_opt exn;
      Prop.exp_normalize_prop tenv prop exp, prop'
  | None, prop' -> Prop.exp_normalize_prop tenv prop exp, prop'

(** Check if [cond] is testing for NULL a pointer already dereferenced *)
let check_already_dereferenced tenv pname cond prop =
  let find_hpred lhs =
    try Some (IList.find (function
        | Sil.Hpointsto (e, _, _) -> Exp.equal e lhs
        | _ -> false) prop.Prop.sigma)
    with Not_found -> None in
  let rec is_check_zero = function
    | Exp.Var id ->
        Some id
    | Exp.UnOp(Unop.LNot, e, _) ->
        is_check_zero e
    | Exp.BinOp ((Binop.Eq | Binop.Ne), Exp.Const Const.Cint i, Exp.Var id)
    | Exp.BinOp ((Binop.Eq | Binop.Ne), Exp.Var id, Exp.Const Const.Cint i) when IntLit.iszero i ->
        Some id
    | _ -> None in
  let dereferenced_line = match is_check_zero cond with
    | Some id ->
        (match find_hpred (Prop.exp_normalize_prop tenv prop (Exp.Var id)) with
         | Some (Sil.Hpointsto (_, se, _)) ->
             (match Tabulation.find_dereference_without_null_check_in_sexp se with
              | Some n -> Some (id, n)
              | None -> None)
         | _ -> None)
    | None ->
        None in
  match dereferenced_line with
  | Some (id, (n, _)) ->
      let desc =
        Errdesc.explain_null_test_after_dereference tenv
          (Exp.Var id) (State.get_node ()) n (State.get_loc ()) in
      let exn =
        (Exceptions.Null_test_after_dereference (desc, __POS__)) in
      let pre_opt = State.get_normalized_pre (Abs.abstract_no_symop pname) in
      Reporting.log_warning pname ?pre:pre_opt exn
  | None -> ()

(** Check whether symbolic execution de-allocated a stack variable or a constant string,
    raising an exception in that case *)
let check_deallocate_static_memory prop_after =
  let check_deallocated_attribute = function
    | Sil.Apred (Aresource ({ ra_kind = Rrelease } as ra), [Lvar pv])
      when Pvar.is_local pv || Pvar.is_global pv ->
        let freed_desc = Errdesc.explain_deallocate_stack_var pv ra in
        raise (Exceptions.Deallocate_stack_variable freed_desc)
    | Sil.Apred (Aresource ({ ra_kind = Rrelease } as ra), [Const (Cstr s)]) ->
        let freed_desc = Errdesc.explain_deallocate_constant_string s ra in
        raise (Exceptions.Deallocate_static_memory freed_desc)
    | _ -> () in
  let exp_att_list = Attribute.get_all prop_after in
  IList.iter check_deallocated_attribute exp_att_list;
  prop_after

let method_exists right_proc_name methods =
  if !Config.curr_language = Config.Java then
    IList.exists (fun meth_name -> Procname.equal right_proc_name meth_name) methods
  else (* ObjC/C++ case : The attribute map will only exist when we have code for the method or
          the method has been called directly somewhere. It can still be that this is not the
          case but we have a model for the method. *)
    match AttributesTable.load_attributes right_proc_name with
    | Some attrs -> attrs.ProcAttributes.is_defined
    | None -> Specs.summary_exists_in_models right_proc_name

let resolve_method tenv class_name proc_name =
  let found_class =
    let visited = ref Typename.Set.empty in
    let rec resolve class_name =
      visited := Typename.Set.add class_name !visited;
      let right_proc_name =
        Procname.replace_class proc_name (Typename.name class_name) in
      match Tenv.lookup tenv class_name with
      | Some { name = TN_csu (Class _, _); def_methods; superclasses } ->
          if method_exists right_proc_name def_methods then
            Some right_proc_name
          else
            (match superclasses with
             | super_classname:: _ ->
                 if not (Typename.Set.mem super_classname !visited)
                 then resolve super_classname
                 else None
             | _ -> None)
      | _ -> None in
    resolve class_name in
  match found_class with
  | None ->
      Logging.d_strln
        ("Couldn't find method in the hierarchy of type "^(Typename.name class_name));
      proc_name
  | Some proc_name ->
      proc_name

let resolve_typename prop receiver_exp =
  let typexp_opt =
    let rec loop = function
      | [] -> None
      | Sil.Hpointsto(e, _, typexp) :: _ when Exp.equal e receiver_exp -> Some typexp
      | _ :: hpreds -> loop hpreds in
    loop prop.Prop.sigma in
  match typexp_opt with
  | Some (Exp.Sizeof (Tstruct { name }, _, _)) -> Some name
  | _ -> None

(** If the dynamic type of the receiver actual T_actual is a subtype of the reciever type T_formal
    in the signature of [pname], resolve [pname] to T_actual.[pname]. *)
let resolve_virtual_pname tenv prop actuals callee_pname call_flags : Procname.t list =
  let resolve receiver_exp pname prop = match resolve_typename prop receiver_exp with
    | Some class_name -> resolve_method tenv class_name pname
    | None -> pname in
  let get_receiver_typ pname fallback_typ =
    match pname with
    | Procname.Java pname_java ->
        begin
          match Tenv.proc_extract_declaring_class_typ tenv pname_java with
          | Some struct_typ -> Typ.Tptr (Tstruct struct_typ, Pk_pointer)
          | None -> fallback_typ
        end
    | _ ->
        fallback_typ in
  let receiver_types_equal pname actual_receiver_typ =
    (* the type of the receiver according to the function signature *)
    let formal_receiver_typ = get_receiver_typ pname actual_receiver_typ in
    Typ.equal formal_receiver_typ actual_receiver_typ in
  let do_resolve called_pname receiver_exp actual_receiver_typ =
    if receiver_types_equal called_pname actual_receiver_typ
    then resolve receiver_exp called_pname prop
    else called_pname in
  match actuals with
  | _ when not (call_flags.CallFlags.cf_virtual || call_flags.CallFlags.cf_interface) ->
      (* if this is not a virtual or interface call, there's no need for resolution *)
      [callee_pname]
  | (receiver_exp, actual_receiver_typ) :: _ ->
      if !Config.curr_language <> Config.Java then
        (* default mode for Obj-C/C++/Java virtual calls: resolution only *)
        [do_resolve callee_pname receiver_exp actual_receiver_typ]
      else if Config.sound_dynamic_dispatch then
        let targets =
          if call_flags.CallFlags.cf_virtual
          then
            (* virtual call--either [called_pname] or an override in some subtype may be called *)
            callee_pname :: call_flags.CallFlags.cf_targets
          else
            (* interface call--[called_pname] has no implementation), we don't want to consider *)
            call_flags.CallFlags.cf_targets (* interface call, don't want to consider *) in
        (* return true if (receiver typ of [target_pname]) <: [actual_receiver_typ] *)
        let may_dispatch_to target_pname =
          let target_receiver_typ = get_receiver_typ target_pname actual_receiver_typ in
          Prover.Subtyping_check.check_subtype tenv target_receiver_typ actual_receiver_typ in
        let resolved_pname = do_resolve callee_pname receiver_exp actual_receiver_typ in
        let feasible_targets = IList.filter may_dispatch_to targets in
        (* make sure [resolved_pname] is not a duplicate *)
        if IList.mem Procname.equal resolved_pname feasible_targets
        then feasible_targets
        else resolved_pname :: feasible_targets
      else
        begin
          match call_flags.CallFlags.cf_targets with
          | target :: _ when call_flags.CallFlags.cf_interface &&
                             receiver_types_equal callee_pname actual_receiver_typ ->
              (* "production mode" of dynamic dispatch for Java: unsound, but faster. the handling
                 is restricted to interfaces: if we can't resolve an interface call, we pick the
                 first implementation of the interface and call it *)
              [target]
          | _ ->
              (* default mode for Java virtual calls: resolution only *)
              [do_resolve callee_pname receiver_exp actual_receiver_typ]
        end
  | _ -> failwith "A virtual call must have a receiver"


(** Resolve the name of the procedure to call based on the type of the arguments *)
let resolve_java_pname tenv prop args pname_java call_flags : Procname.java =
  let resolve_from_args resolved_pname_java args =
    let parameters = Procname.java_get_parameters resolved_pname_java in
    if IList.length args <> IList.length parameters then
      resolved_pname_java
    else
      let resolved_params =
        IList.fold_left2
          (fun accu (arg_exp, _) name ->
             match resolve_typename prop arg_exp with
             | Some class_name ->
                 (Procname.split_classname (Typename.name class_name)) :: accu
             | None -> name :: accu)
          [] args (Procname.java_get_parameters resolved_pname_java) |> IList.rev in
      Procname.java_replace_parameters resolved_pname_java resolved_params in
  let resolved_pname_java, other_args =
    match args with
    | [] ->
        pname_java, []
    | (first_arg, _) :: other_args when call_flags.CallFlags.cf_virtual ->
        let resolved =
          begin
            match resolve_typename prop first_arg with
            | Some class_name ->
                begin
                  match resolve_method tenv class_name (Procname.Java pname_java) with
                  | Procname.Java resolved_pname_java ->
                      resolved_pname_java
                  | _ ->
                      pname_java
                end
            | None ->
                pname_java
          end in
        resolved, other_args
    | _ :: other_args when Procname.is_constructor (Procname.Java pname_java) ->
        pname_java, other_args
    | args ->
        pname_java, args in
  resolve_from_args resolved_pname_java other_args


(** Resolve the procedure name and run the analysis of the resolved procedure
    if not already analyzed *)
let resolve_and_analyze
    tenv caller_pdesc prop args callee_proc_name call_flags : Procname.t * Specs.summary option =
  (* TODO (#9333890): Fix conflict with method overloading by encoding in the procedure name
     whether the method is defined or generated by the specialization *)
  let analyze_ondemand resolved_pname : unit =
    if Procname.equal resolved_pname callee_proc_name then
      Ondemand.analyze_proc_name tenv ~propagate_exceptions:true caller_pdesc callee_proc_name
    else
      (* Create the type sprecialized procedure description and analyze it directly *)
      Option.may
        (fun specialized_pdesc ->
           Ondemand.analyze_proc_desc tenv ~propagate_exceptions:true caller_pdesc specialized_pdesc)
        (match Ondemand.get_proc_desc resolved_pname with
         | Some resolved_proc_desc ->
             Some resolved_proc_desc
         | None ->
             begin
               Option.map
                 (fun callee_proc_desc ->
                    Cfg.specialize_types callee_proc_desc resolved_pname args)
                 (Ondemand.get_proc_desc callee_proc_name)
             end) in
  let resolved_pname = match callee_proc_name with
    | Procname.Java callee_proc_name_java ->
        Procname.Java
          (resolve_java_pname tenv prop args callee_proc_name_java call_flags)
    | _ ->
        callee_proc_name in
  analyze_ondemand resolved_pname;
  resolved_pname, Specs.get_summary resolved_pname


(** recognize calls to the constructor java.net.URL and splits the argument string
    to be only the protocol.  *)
let call_constructor_url_update_args pname actual_params =
  let url_pname =
    Procname.Java
      (Procname.java
         ((Some "java.net"), "URL") None "<init>"
         [(Some "java.lang"), "String"] Procname.Non_Static) in
  if (Procname.equal url_pname pname) then
    (match actual_params with
     | [this; (Exp.Const (Const.Cstr s), atype)] ->
         let parts = Str.split (Str.regexp_string "://") s in
         (match parts with
          | frst:: _ ->
              if frst = "http" ||
                 frst = "ftp" ||
                 frst = "https" ||
                 frst = "mailto" ||
                 frst = "jar"
              then
                [this; (Exp.Const (Const.Cstr frst), atype)]
              else actual_params
          | _ -> actual_params)
     | [this; _, atype] -> [this; (Exp.Const (Const.Cstr "file"), atype)]
     | _ -> actual_params)
  else actual_params

(* This method is used to handle the special semantics of ObjC instance method calls. *)
(* res = [obj foo] *)
(*  1. We know that obj is null, then we return null *)
(*  2. We don't know, but obj could be null, we return both options, *)
(* (obj = null, res = null), (obj != null, res = [obj foo]) *)
(*  We want the same behavior even when we are going to skip the function. *)
let handle_objc_instance_method_call_or_skip tenv actual_pars path callee_pname pre ret_ids res =
  let path_description =
    "Message " ^
    (Procname.to_simplified_string callee_pname) ^
    " with receiver nil returns nil." in
  let receiver = (match actual_pars with
      | (e, _):: _ -> e
      | _ -> raise
               (Exceptions.Internal_error
                  (Localise.verbatim_desc
                     "In Objective-C instance method call there should be a receiver."))) in
  let is_receiver_null =
    match actual_pars with
    | (e, _) :: _
      when Exp.equal e Exp.zero ||
           Option.is_some (Attribute.get_objc_null tenv pre e) -> true
    | _ -> false in
  let add_objc_null_attribute_or_nullify_result prop =
    match ret_ids with
    | [ret_id] -> (
        match Attribute.find_equal_formal_path tenv receiver prop with
        | Some vfs ->
            Attribute.add_or_replace tenv prop (Apred (Aobjc_null, [Exp.Var ret_id; vfs]))
        | None ->
            Prop.conjoin_eq tenv (Exp.Var ret_id) Exp.zero prop
      )
    | _ -> prop in
  if is_receiver_null then
    (* objective-c instance method with a null receiver just return objc_null(res) *)
    let path = Paths.Path.add_description path path_description in
    L.d_strln
      ("Object-C method " ^
       Procname.to_string callee_pname ^
       " called with nil receiver. Returning 0/nil");
    (* We wish to nullify the result. However, in some cases,
       we want to add the attribute OBJC_NULL to it so that we *)
    (* can keep track of how this object became null,
       so that in a NPE we can separate it into a different error type *)
    [(add_objc_null_attribute_or_nullify_result pre, path)]
  else
    let is_undef = Option.is_some (Attribute.get_undef tenv pre receiver) in
    if !Config.footprint && not is_undef then
      let res_null = (* returns: (objc_null(res) /\ receiver=0) or an empty list of results *)
        let pre_with_attr_or_null = add_objc_null_attribute_or_nullify_result pre in
        let propset = prune_ne tenv ~positive:false receiver Exp.zero pre_with_attr_or_null in
        if Propset.is_empty propset then []
        else
          let prop = IList.hd (Propset.to_proplist propset) in
          let path = Paths.Path.add_description path path_description in
          [(prop, path)] in
      res_null @ (res ())
    else res () (* Not known if receiver = 0 and not footprint. Standard tabulation *)

(* This method handles ObjC instance method calls, in particular the fact that calling a method *)
(* with nil returns nil. The exec_call function is either standard call execution or execution *)
(* of ObjC getters and setters using a builtin. *)
let handle_objc_instance_method_call actual_pars actual_params pre tenv ret_ids pdesc callee_pname
    loc path exec_call =
  let res () = exec_call tenv ret_ids pdesc callee_pname loc actual_params pre path in
  handle_objc_instance_method_call_or_skip tenv actual_pars path callee_pname pre ret_ids res

let normalize_params tenv pdesc prop actual_params =
  let norm_arg (p, args) (e, t) =
    let e', p' = check_arith_norm_exp tenv pdesc e p in
    (p', (e', t) :: args) in
  let prop, args = IList.fold_left norm_arg (prop, []) actual_params in
  (prop, IList.rev args)

let do_error_checks tenv node_opt instr pname pdesc = match node_opt with
  | Some node ->
      if !Config.curr_language = Config.Java then
        PrintfArgs.check_printf_args_ok tenv node instr pname pdesc
  | None ->
      ()

let add_strexp_to_footprint tenv strexp abduced_pv typ prop =
  let abduced_lvar = Exp.Lvar abduced_pv in
  let lvar_pt_fpvar =
    let sizeof_exp = Exp.Sizeof (typ, None, Subtype.subtypes) in
    Prop.mk_ptsto tenv abduced_lvar strexp sizeof_exp in
  let sigma_fp = prop.Prop.sigma_fp in
  Prop.normalize tenv (Prop.set prop ~sigma_fp:(lvar_pt_fpvar :: sigma_fp))

let add_to_footprint tenv abduced_pv typ prop =
  let fresh_fp_var = Exp.Var (Ident.create_fresh Ident.kfootprint) in
  let prop' =
    add_strexp_to_footprint tenv (Sil.Eexp (fresh_fp_var, Sil.Inone)) abduced_pv typ prop in
  prop', fresh_fp_var

(* the current abduction mechanism treats struct values differently than all other types. abduction
   on struct values adds a a struct whose fields are initialized to fresh footprint vars to the
   footprint. regular abduction just adds a fresh footprint value of the correct type to the
   footprint. we can get rid of this special case if we fix the abduction on struct values *)
let add_struct_value_to_footprint tenv abduced_pv typ prop =
  let struct_strexp =
    Prop.create_strexp_of_type tenv Prop.Fld_init typ None Sil.inst_none in
  let prop' = add_strexp_to_footprint tenv struct_strexp abduced_pv typ prop in
  prop', struct_strexp

let add_constraints_on_retval tenv pdesc prop ret_exp ~has_nullable_annot typ callee_pname callee_loc=
  if Procname.is_infer_undefined callee_pname then prop
  else
    let is_rec_call pname = (* TODO: (t7147096) extend this to detect mutual recursion *)
      Procname.equal pname (Cfg.Procdesc.get_proc_name pdesc) in
    let already_has_abduced_retval p abduced_ret_pv =
      IList.exists
        (fun hpred -> match hpred with
           | Sil.Hpointsto (Exp.Lvar pv, _, _) -> Pvar.equal pv abduced_ret_pv
           | _ -> false)
        p.Prop.sigma_fp in
    (* find an hpred [abduced] |-> A in [prop] and add [exp] = A to prop *)
    let bind_exp_to_abduced_val exp_to_bind abduced prop =
      let bind_exp prop = function
        | Sil.Hpointsto (Exp.Lvar pv, Sil.Eexp (rhs, _), _)
          when Pvar.equal pv abduced ->
            Prop.conjoin_eq tenv exp_to_bind rhs prop
        | _ -> prop in
      IList.fold_left bind_exp prop prop.Prop.sigma in
    (* To avoid obvious false positives, assume skip functions do not return null pointers *)
    let add_ret_non_null exp typ prop =
      if has_nullable_annot
      then
        prop (* don't assume nonnull if the procedure is annotated with @Nullable *)
      else
        match typ with
        | Typ.Tptr _ -> Prop.conjoin_neq tenv exp Exp.zero prop
        | _ -> prop in
    let add_tainted_post ret_exp callee_pname prop =
      Attribute.add_or_replace tenv prop (Apred (Ataint callee_pname, [ret_exp])) in

    if Config.angelic_execution && not (is_rec_call callee_pname) then
      (* introduce a fresh program variable to allow abduction on the return value *)
      let abduced_ret_pv = Pvar.mk_abduced_ret callee_pname callee_loc in
      (* prevent introducing multiple abduced retvals for a single call site in a loop *)
      if already_has_abduced_retval prop abduced_ret_pv then prop
      else
        let prop' =
          if !Config.footprint then
            let (prop', fresh_fp_var) = add_to_footprint tenv abduced_ret_pv typ prop in
            Prop.conjoin_eq tenv ~footprint: true ret_exp fresh_fp_var prop'
          else
            (* bind return id to the abduced value pointed to by the pvar we introduced *)
            bind_exp_to_abduced_val ret_exp abduced_ret_pv prop in
        let prop'' = add_ret_non_null ret_exp typ prop' in
        if Config.taint_analysis then
          match Taint.returns_tainted callee_pname None with
          | Some taint_kind ->
              add_tainted_post ret_exp { taint_source = callee_pname; taint_kind; } prop''
          | None -> prop''
        else prop''
    else add_ret_non_null ret_exp typ prop

let add_taint prop lhs_id rhs_exp pname tenv  =
  let add_attribute_if_field_tainted prop fieldname struct_typ =
    if Taint.has_taint_annotation fieldname struct_typ
    then
      let taint_info = { PredSymb.taint_source = pname; taint_kind = Tk_unknown; } in
      Attribute.add_or_replace tenv prop (Apred (Ataint taint_info, [Exp.Var lhs_id]))
    else
      prop in
  match rhs_exp with
  | Exp.Lfield (_, fieldname, Tptr (Tstruct struct_typ, _))
  | Exp.Lfield (_, fieldname, Tstruct struct_typ) ->
      add_attribute_if_field_tainted prop fieldname struct_typ
  | Exp.Lfield (_, fieldname, Tptr (Tvar typname, _))
  | Exp.Lfield (_, fieldname, Tvar typname) ->
      begin
        match Tenv.lookup tenv typname with
        | Some struct_typ -> add_attribute_if_field_tainted prop fieldname struct_typ
        | None -> prop
      end
  | _ -> prop

let execute_load ?(report_deref_errors=true) pname pdesc tenv id rhs_exp typ loc prop_ =
  let execute_load_ pdesc tenv id loc acc_in iter =
    let iter_ren = Prop.prop_iter_make_id_primed tenv id iter in
    let prop_ren = Prop.prop_iter_to_prop tenv iter_ren in
    match Prop.prop_iter_current tenv iter_ren with
    | (Sil.Hpointsto(lexp, strexp, Exp.Sizeof (typ, len, st)), offlist) ->
        let contents, new_ptsto, pred_insts_op, lookup_uninitialized =
          ptsto_lookup pdesc tenv prop_ren (lexp, strexp, typ, len, st) offlist id in
        let update acc (pi, sigma) =
          let pi' = Sil.Aeq (Exp.Var(id), contents):: pi in
          let sigma' = new_ptsto:: sigma in
          let iter' = update_iter iter_ren pi' sigma' in
          let prop' = Prop.prop_iter_to_prop tenv iter' in
          let prop'' =
            if lookup_uninitialized then
              Attribute.add_or_replace tenv prop' (Apred (Adangling DAuninit, [Exp.Var id]))
            else prop' in
          let prop''' =
            if Config.taint_analysis
            then add_taint prop'' id rhs_exp pname tenv
            else prop'' in
          prop''' :: acc in
        begin
          match pred_insts_op with
          | None -> update acc_in ([],[])
          | Some pred_insts -> IList.rev (IList.fold_left update acc_in pred_insts)
        end
    | (Sil.Hpointsto _, _) ->
        Errdesc.warning_err loc "no offset access in execute_load -- treating as skip@.";
        (Prop.prop_iter_to_prop tenv iter_ren) :: acc_in
    | _ ->
        (* The implementation of this case means that we
           ignore this dereferencing operator. When the analyzer treats
           numerical information and arrays more precisely later, we
           should change the implementation here. *)
        assert false in
  try
    let n_rhs_exp, prop = check_arith_norm_exp tenv pname rhs_exp prop_ in
    let n_rhs_exp' = Prop.exp_collapse_consecutive_indices_prop tenv typ n_rhs_exp in
    match check_constant_string_dereference n_rhs_exp' with
    | Some value ->
        [Prop.conjoin_eq tenv (Exp.Var id) value prop]
    | None ->
        let exp_get_undef_attr exp =
          let fold_undef_pname callee_opt atom =
            match callee_opt, atom with
            | None, Sil.Apred (Aundef _, _) -> Some atom
            | _ -> callee_opt in
          IList.fold_left fold_undef_pname None (Attribute.get_for_exp tenv prop exp) in
        let prop' =
          if Config.angelic_execution then
            (* when we try to deref an undefined value, add it to the footprint *)
            match exp_get_undef_attr n_rhs_exp' with
            | Some (Apred (Aundef (callee_pname, ret_annots, callee_loc, _), _)) ->
                let has_nullable_annot = Annotations.ia_is_nullable ret_annots in
                add_constraints_on_retval tenv
                  pdesc prop n_rhs_exp' ~has_nullable_annot typ callee_pname callee_loc
            | _ -> prop
          else prop in
        let iter_list =
          Rearrange.rearrange ~report_deref_errors pdesc tenv n_rhs_exp' typ prop' loc in
        IList.rev (IList.fold_left (execute_load_ pdesc tenv id loc) [] iter_list)
  with Rearrange.ARRAY_ACCESS ->
    if (Config.array_level = 0) then assert false
    else
      let undef = Exp.get_undefined false in
      [Prop.conjoin_eq tenv (Exp.Var id) undef prop_]

let load_ret_annots pname =
  match AttributesTable.load_attributes pname with
  | Some attrs ->
      let ret_annots, _ = attrs.ProcAttributes.method_annotation in
      ret_annots
  | None ->
      Typ.item_annotation_empty

let execute_store ?(report_deref_errors=true) pname pdesc tenv lhs_exp typ rhs_exp loc prop_ =
  let execute_store_ pdesc tenv rhs_exp acc_in iter =
    let (lexp, strexp, typ, len, st, offlist) =
      match Prop.prop_iter_current tenv iter with
      | (Sil.Hpointsto(lexp, strexp, Exp.Sizeof (typ, len, st)), offlist) ->
          (lexp, strexp, typ, len, st, offlist)
      | _ -> assert false in
    let p = Prop.prop_iter_to_prop tenv iter in
    let new_ptsto, pred_insts_op =
      ptsto_update pdesc tenv p (lexp, strexp, typ, len, st) offlist rhs_exp in
    let update acc (pi, sigma) =
      let sigma' = new_ptsto:: sigma in
      let iter' = update_iter iter pi sigma' in
      let prop' = Prop.prop_iter_to_prop tenv iter' in
      prop' :: acc in
    match pred_insts_op with
    | None -> update acc_in ([],[])
    | Some pred_insts -> IList.fold_left update acc_in pred_insts in
  try
    let n_lhs_exp, prop_' = check_arith_norm_exp tenv pname lhs_exp prop_ in
    let n_rhs_exp, prop = check_arith_norm_exp tenv pname rhs_exp prop_' in
    let prop = Attribute.replace_objc_null tenv prop n_lhs_exp n_rhs_exp in
    let n_lhs_exp' = Prop.exp_collapse_consecutive_indices_prop tenv typ n_lhs_exp in
    let iter_list = Rearrange.rearrange ~report_deref_errors pdesc tenv n_lhs_exp' typ prop loc in
    IList.rev (IList.fold_left (execute_store_ pdesc tenv n_rhs_exp) [] iter_list)
  with Rearrange.ARRAY_ACCESS ->
    if (Config.array_level = 0) then assert false
    else [prop_]

(** Execute [instr] with a symbolic heap [prop].*)
let rec sym_exec tenv current_pdesc _instr (prop_: Prop.normal Prop.t) path
  : (Prop.normal Prop.t * Paths.Path.t) list =
  let current_pname = Cfg.Procdesc.get_proc_name current_pdesc in
  State.set_instr _instr; (* mark instruction last seen *)
  State.set_prop_tenv_pdesc prop_ tenv current_pdesc; (* mark prop,tenv,pdesc last seen *)
  SymOp.pay(); (* pay one symop *)
  let ret_old_path pl = (* return the old path unchanged *)
    IList.map (fun p -> (p, path)) pl in
  let instr = match _instr with
    | Sil.Call (ret, exp, par, loc, call_flags) ->
        let exp' = Prop.exp_normalize_prop tenv prop_ exp in
        let instr' = match exp' with
          | Exp.Closure c ->
              let proc_exp = Exp.Const (Const.Cfun c.name) in
              let proc_exp' = Prop.exp_normalize_prop tenv prop_ proc_exp in
              let par' = IList.map (fun (id_exp, _, typ) -> (id_exp, typ)) c.captured_vars in
              Sil.Call (ret, proc_exp', par' @ par, loc, call_flags)
          | _ ->
              Sil.Call (ret, exp', par, loc, call_flags) in
        instr'
    | _ -> _instr in
  let skip_call ?(is_objc_instance_method=false) prop path callee_pname ret_annots loc ret_ids
      ret_typ_opt actual_args =
    let skip_res () =
      let exn = Exceptions.Skip_function (Localise.desc_skip_function callee_pname) in
      Reporting.log_info current_pname exn;
      L.d_strln
        ("Undefined function " ^ Procname.to_string callee_pname
         ^ ", returning undefined value.");
      (match Specs.get_summary current_pname with
       | None -> ()
       | Some summary ->
           Specs.CallStats.trace
             summary.Specs.stats.Specs.call_stats callee_pname loc
             (Specs.CallStats.CR_skip) !Config.footprint);
      unknown_or_scan_call ~is_scan:false ret_typ_opt ret_annots Builtin.{
          pdesc= current_pdesc; instr; tenv; prop_= prop; path; ret_ids; args= actual_args;
          proc_name= callee_pname; loc; } in
    if is_objc_instance_method then
      handle_objc_instance_method_call_or_skip tenv actual_args path callee_pname prop ret_ids skip_res
    else skip_res () in
  let call_args prop_ proc_name args ret_ids loc = {
    Builtin.pdesc = current_pdesc; instr; tenv; prop_; path; ret_ids; args; proc_name; loc; } in
  match instr with
  | Sil.Load (id, rhs_exp, typ, loc) ->
      execute_load current_pname current_pdesc tenv id rhs_exp typ loc prop_
      |> ret_old_path
  | Sil.Store (lhs_exp, typ, rhs_exp, loc) ->
      execute_store current_pname current_pdesc tenv lhs_exp typ rhs_exp loc prop_
      |> ret_old_path
  | Sil.Prune (cond, loc, true_branch, ik) ->
      let prop__ = Attribute.nullify_exp_with_objc_null tenv prop_ cond in
      let check_condition_always_true_false () =
        let report_condition_always_true_false i =
          let skip_loop = match ik with
            | Sil.Ik_while | Sil.Ik_for ->
                not (IntLit.iszero i) (* skip wile(1) and for (;1;) *)
            | Sil.Ik_dowhile ->
                true (* skip do..while *)
            | Sil.Ik_land_lor ->
                true (* skip subpart of a condition obtained from compilation of && and || *)
            | _ -> false in
          true_branch && not skip_loop in
        match Prop.exp_normalize_prop tenv Prop.prop_emp cond with
        | Exp.Const (Const.Cint i) when report_condition_always_true_false i ->
            let node = State.get_node () in
            let desc = Errdesc.explain_condition_always_true_false tenv i cond node loc in
            let exn =
              Exceptions.Condition_always_true_false (desc, not (IntLit.iszero i), __POS__) in
            let pre_opt = State.get_normalized_pre (Abs.abstract_no_symop current_pname) in
            Reporting.log_warning current_pname ?pre:pre_opt exn
        | _ -> () in
      if not Config.report_runtime_exceptions then
        check_already_dereferenced tenv current_pname cond prop__;
      check_condition_always_true_false ();
      let n_cond, prop = check_arith_norm_exp tenv current_pname cond prop__ in
      ret_old_path (Propset.to_proplist (prune tenv ~positive:true n_cond prop))
  | Sil.Call (ret_ids, Exp.Const (Const.Cfun callee_pname), args, loc, _)
    when Builtin.is_registered callee_pname ->
      let sym_exe_builtin = Builtin.get callee_pname in
      sym_exe_builtin (call_args prop_ callee_pname args ret_ids loc)
  | Sil.Call (ret_ids,
              Exp.Const (Const.Cfun ((Procname.Java callee_pname_java) as callee_pname)),
              actual_params, loc, call_flags)
    when Config.lazy_dynamic_dispatch ->
      let norm_prop, norm_args = normalize_params tenv current_pname prop_ actual_params in
      let exec_skip_call skipped_pname ret_annots ret_type =
        skip_call norm_prop path skipped_pname ret_annots loc ret_ids (Some ret_type) norm_args in
      let resolved_pname, summary_opt =
        resolve_and_analyze tenv current_pdesc norm_prop norm_args callee_pname call_flags in
      begin
        match summary_opt with
        | None ->
            let ret_typ =
              match Tenv.proc_extract_return_typ tenv callee_pname_java with
              | Some (Typ.Tstruct _ as typ) -> Typ.Tptr (typ, Pk_pointer)
              | Some typ -> typ
              | None -> Typ.Tvoid in
            let ret_annots = load_ret_annots callee_pname in
            exec_skip_call resolved_pname ret_annots ret_typ
        | Some summary when call_should_be_skipped resolved_pname summary ->
            let proc_attrs = summary.Specs.attributes in
            let ret_annots, _ = proc_attrs.ProcAttributes.method_annotation in
            exec_skip_call resolved_pname ret_annots proc_attrs.ProcAttributes.ret_type
        | Some summary ->
            proc_call summary (call_args prop_ callee_pname norm_args ret_ids loc)
      end

  | Sil.Call (ret_ids,
              Exp.Const (Const.Cfun ((Procname.Java callee_pname_java) as callee_pname)),
              actual_params, loc, call_flags) ->
      do_error_checks tenv (Paths.Path.curr_node path) instr current_pname current_pdesc;
      let norm_prop, norm_args = normalize_params tenv current_pname prop_ actual_params in
      let url_handled_args =
        call_constructor_url_update_args callee_pname norm_args in
      let resolved_pnames =
        resolve_virtual_pname tenv norm_prop url_handled_args callee_pname call_flags in
      let exec_one_pname pname =
        Ondemand.analyze_proc_name tenv ~propagate_exceptions:true current_pdesc pname;
        let exec_skip_call ret_annots ret_type =
          skip_call norm_prop path pname ret_annots loc ret_ids (Some ret_type) url_handled_args in
        match Specs.get_summary pname with
        | None ->
            let ret_typ =
              match Tenv.proc_extract_return_typ tenv callee_pname_java with
              | Some (Typ.Tstruct _ as typ) -> Typ.Tptr (typ, Pk_pointer)
              | Some typ -> typ
              | None -> Typ.Tvoid in
            let ret_annots = load_ret_annots callee_pname in
            exec_skip_call ret_annots ret_typ
        | Some summary when call_should_be_skipped pname summary ->
            let proc_attrs = summary.Specs.attributes in
            let ret_annots, _ = proc_attrs.ProcAttributes.method_annotation in
            exec_skip_call ret_annots proc_attrs.ProcAttributes.ret_type
        | Some summary ->
            proc_call summary (call_args norm_prop pname url_handled_args ret_ids loc) in
      IList.fold_left (fun acc pname -> exec_one_pname pname @ acc) [] resolved_pnames

  | Sil.Call (ret_ids, Exp.Const (Const.Cfun callee_pname), actual_params, loc, call_flags) ->
      (* Generic fun call with known name *)
      let (prop_r, n_actual_params) = normalize_params tenv current_pname prop_ actual_params in
      let resolved_pname =
        match resolve_virtual_pname tenv prop_r n_actual_params callee_pname call_flags with
        | resolved_pname :: _ -> resolved_pname
        | [] -> callee_pname in

      Ondemand.analyze_proc_name tenv ~propagate_exceptions:true current_pdesc resolved_pname;

      let callee_pdesc_opt = Ondemand.get_proc_desc resolved_pname in

      let ret_typ_opt = Option.map Cfg.Procdesc.get_ret_type callee_pdesc_opt in
      let sentinel_result =
        if !Config.curr_language = Config.Clang then
          check_variadic_sentinel_if_present
            (call_args prop_r callee_pname actual_params ret_ids loc)
        else [(prop_r, path)] in
      let do_call (prop, path) =
        let summary = Specs.get_summary resolved_pname in
        let should_skip resolved_pname summary =
          match summary with
          | None -> true
          | Some summary -> call_should_be_skipped resolved_pname summary in
        if should_skip resolved_pname summary then
          (* If it's an ObjC getter or setter, call the builtin rather than skipping *)
          let attrs_opt =
            let attr_opt = Option.map Cfg.Procdesc.get_attributes callee_pdesc_opt in
            match attr_opt, resolved_pname with
            | Some attrs, Procname.ObjC_Cpp _ -> Some attrs
            | None, Procname.ObjC_Cpp _ -> AttributesTable.load_attributes resolved_pname
            | _ -> None in
          let objc_property_accessor_ret_typ_opt =
            match attrs_opt with
            | Some attrs ->
                (match attrs.ProcAttributes.objc_accessor with
                 | Some objc_accessor -> Some (objc_accessor, attrs.ProcAttributes.ret_type)
                 | None -> None)
            | None -> None in
          match objc_property_accessor_ret_typ_opt with
          | Some (objc_property_accessor, ret_typ) ->
              handle_objc_instance_method_call
                n_actual_params n_actual_params prop tenv ret_ids
                current_pdesc callee_pname loc path
                (sym_exec_objc_accessor objc_property_accessor ret_typ)
          | None ->
              let ret_annots = match summary with
                | Some summ ->
                    let ret_annots, _ = summ.Specs.attributes.ProcAttributes.method_annotation in
                    ret_annots
                | None ->
                    load_ret_annots resolved_pname in
              let is_objc_instance_method =
                match attrs_opt with
                | Some attrs -> attrs.ProcAttributes.is_objc_instance_method
                | None -> false in
              skip_call ~is_objc_instance_method prop path resolved_pname ret_annots loc ret_ids
                ret_typ_opt n_actual_params
        else
          proc_call (Option.get summary)
            (call_args prop resolved_pname n_actual_params ret_ids loc) in
      IList.flatten (IList.map do_call sentinel_result)
  | Sil.Call (ret_ids, fun_exp, actual_params, loc, call_flags) -> (* Call via function pointer *)
      let (prop_r, n_actual_params) = normalize_params tenv current_pname prop_ actual_params in
      if call_flags.CallFlags.cf_is_objc_block then
        Rearrange.check_call_to_objc_block_error tenv current_pdesc prop_r fun_exp loc;
      Rearrange.check_dereference_error tenv current_pdesc prop_r fun_exp loc;
      if call_flags.CallFlags.cf_noreturn then begin
        L.d_str "Unknown function pointer with noreturn attribute ";
        Sil.d_exp fun_exp; L.d_strln ", diverging.";
        diverge prop_r path
      end else begin
        L.d_str "Unknown function pointer "; Sil.d_exp fun_exp;
        L.d_strln ", returning undefined value.";
        let callee_pname = Procname.from_string_c_fun "__function_pointer__" in
        unknown_or_scan_call ~is_scan:false None Typ.item_annotation_empty Builtin.{
            pdesc= current_pdesc; instr; tenv; prop_= prop_r; path; ret_ids; args= n_actual_params;
            proc_name= callee_pname; loc; }
      end
  | Sil.Nullify (pvar, _) ->
      begin
        let eprop = Prop.expose prop_ in
        match IList.partition
                (function
                  | Sil.Hpointsto (Exp.Lvar pvar', _, _) -> Pvar.equal pvar pvar'
                  | _ -> false) eprop.Prop.sigma with
        | [Sil.Hpointsto(e, se, typ)], sigma' ->
            let sigma'' =
              let se' = execute_nullify_se se in
              Sil.Hpointsto(e, se', typ):: sigma' in
            let eprop_res = Prop.set eprop ~sigma:sigma'' in
            ret_old_path [Prop.normalize tenv eprop_res]
        | [], _ ->
            ret_old_path [prop_]
        | _ ->
            L.err "Pvar %a appears on the LHS of >1 heap predicate!@." (Pvar.pp pe_text) pvar;
            assert false
      end
  | Sil.Abstract _ ->
      let node = State.get_node () in
      let blocks_nullified = get_blocks_nullified node in
      IList.iter (check_block_retain_cycle tenv current_pname prop_) blocks_nullified;
      if Prover.check_inconsistency tenv prop_
      then
        ret_old_path []
      else
        ret_old_path
          [Abs.remove_redundant_array_elements current_pname tenv
             (Abs.abstract current_pname tenv prop_)]
  | Sil.Remove_temps (temps, _) ->
      ret_old_path [Prop.exist_quantify tenv (Sil.fav_from_list temps) prop_]
  | Sil.Declare_locals (ptl, _) ->
      let sigma_locals =
        let add_None (x, y) = (x, Exp.Sizeof (y, None, Subtype.exact), None) in
        let sigma_locals () =
          IList.map
            (Prop.mk_ptsto_lvar tenv Prop.Fld_init Sil.inst_initial)
            (IList.map add_None ptl) in
        Config.run_in_re_execution_mode (* no footprint vars for locals *)
          sigma_locals () in
      let sigma' = prop_.Prop.sigma @ sigma_locals in
      let prop' = Prop.normalize tenv (Prop.set prop_ ~sigma:sigma') in
      ret_old_path [prop']
and diverge prop path =
  State.add_diverging_states (Paths.PathSet.from_renamed_list [(prop, path)]); (* diverge *)
  []

(** Symbolic execution of a sequence of instructions.
    If errors occur and [mask_errors] is true, just treat as skip. *)
and instrs ?(mask_errors=false) tenv pdesc instrs ppl =
  let exe_instr instr (p, path) =
    L.d_str "Executing Generated Instruction "; Sil.d_instr instr; L.d_ln ();
    try sym_exec tenv pdesc instr p path
    with exn when SymOp.exn_not_failure exn && mask_errors ->
      let err_name, _, ml_source, _ , _, _, _ = Exceptions.recognize_exception exn in
      let loc = (match ml_source with
          | Some ml_loc -> "at " ^ (L.ml_loc_to_string ml_loc)
          | None -> "") in
      L.d_warning
        ("Generated Instruction Failed with: " ^
         (Localise.to_string err_name)^loc ); L.d_ln();
      [(p, path)] in
  let f plist instr = IList.flatten (IList.map (exe_instr instr) plist) in
  IList.fold_left f ppl instrs

and add_constraints_on_actuals_by_ref tenv prop actuals_by_ref callee_pname callee_loc =
  (* replace an hpred of the form actual_var |-> _ with new_hpred in prop *)
  let replace_actual_hpred actual_var new_hpred prop =
    let sigma' =
      IList.map
        (function
          | Sil.Hpointsto (lhs, _, _) when Exp.equal lhs actual_var -> new_hpred
          | hpred -> hpred)
        prop.Prop.sigma in
    Prop.normalize tenv (Prop.set prop ~sigma:sigma') in
  let add_actual_by_ref_to_footprint prop (actual, actual_typ, _) =
    match actual with
    | Exp.Lvar actual_pv ->
        (* introduce a fresh program variable to allow abduction on the return value *)
        let abduced_ref_pv =
          Pvar.mk_abduced_ref_param callee_pname actual_pv callee_loc in
        let already_has_abduced_retval p =
          IList.exists
            (fun hpred -> match hpred with
               | Sil.Hpointsto (Exp.Lvar pv, _, _) -> Pvar.equal pv abduced_ref_pv
               | _ -> false)
            p.Prop.sigma_fp in
        (* prevent introducing multiple abduced retvals for a single call site in a loop *)
        if already_has_abduced_retval prop then prop
        else
        if !Config.footprint then
          let prop', abduced_strexp = match actual_typ with
            | Typ.Tptr ((Typ.Tstruct _) as typ, _) ->
                (* for struct types passed by reference, do abduction on the fields of the
                   struct *)
                add_struct_value_to_footprint tenv abduced_ref_pv typ prop
            | Typ.Tptr (typ, _) ->
                (* for pointer types passed by reference, do abduction directly on the pointer *)
                let (prop', fresh_fp_var) =
                  add_to_footprint tenv abduced_ref_pv typ prop in
                prop', Sil.Eexp (fresh_fp_var, Sil.Inone)
            | typ ->
                failwith
                  ("No need for abduction on non-pointer type " ^
                   (Typ.to_string typ)) in
          (* replace [actual] |-> _ with [actual] |-> [fresh_fp_var] *)
          let filtered_sigma =
            IList.map
              (function
                | Sil.Hpointsto (lhs, _, typ_exp) when Exp.equal lhs actual ->
                    Sil.Hpointsto (lhs, abduced_strexp, typ_exp)
                | hpred -> hpred)
              prop'.Prop.sigma in
          Prop.normalize tenv (Prop.set prop' ~sigma:filtered_sigma)
        else
          (* bind actual passed by ref to the abduced value pointed to by the synthetic pvar *)
          let prop' =
            let filtered_sigma =
              IList.filter
                (function
                  | Sil.Hpointsto (lhs, _, _) when Exp.equal lhs actual ->
                      false
                  | _ -> true)
                prop.Prop.sigma in
            Prop.normalize tenv (Prop.set prop ~sigma:filtered_sigma) in
          IList.fold_left
            (fun p hpred ->
               match hpred with
               | Sil.Hpointsto (Exp.Lvar pv, rhs, texp) when Pvar.equal pv abduced_ref_pv ->
                   let new_hpred = Sil.Hpointsto (actual, rhs, texp) in
                   Prop.normalize tenv (Prop.set p ~sigma:(new_hpred :: prop'.Prop.sigma))
               | _ -> p)
            prop'
            prop'.Prop.sigma
    | _ -> assert false in
  (* non-angelic mode; havoc each var passed by reference by assigning it to a fresh id *)
  let havoc_actual_by_ref prop (actual, actual_typ, _) =
    let actual_pt_havocd_var =
      let havocd_var = Exp.Var (Ident.create_fresh Ident.kprimed) in
      let sizeof_exp = Exp.Sizeof (Typ.strip_ptr actual_typ, None, Subtype.subtypes) in
      Prop.mk_ptsto tenv actual (Sil.Eexp (havocd_var, Sil.Inone)) sizeof_exp in
    replace_actual_hpred actual actual_pt_havocd_var prop in
  let do_actual_by_ref =
    if Config.angelic_execution then add_actual_by_ref_to_footprint
    else havoc_actual_by_ref in
  let non_const_actuals_by_ref =
    let is_not_const (e, _, i) =
      match AttributesTable.load_attributes callee_pname with
      | Some attrs ->
          let is_const = IList.mem int_equal i attrs.ProcAttributes.const_formals in
          if is_const then (
            L.d_str (Printf.sprintf "Not havocing const argument number %d: " i);
            Sil.d_exp e;
            L.d_ln ()
          );
          not is_const
      | None ->
          true in
    IList.filter is_not_const actuals_by_ref in
  IList.fold_left do_actual_by_ref prop non_const_actuals_by_ref

and check_untainted tenv exp taint_kind caller_pname callee_pname prop =
  match Attribute.get_taint tenv prop exp with
  | Some (Apred (Ataint taint_info, _)) ->
      let err_desc =
        Errdesc.explain_tainted_value_reaching_sensitive_function
          prop
          exp
          taint_info
          callee_pname
          (State.get_loc ()) in
      let exn =
        Exceptions.Tainted_value_reaching_sensitive_function
          (err_desc, __POS__) in
      Reporting.log_warning caller_pname exn;
      Attribute.add_or_replace tenv prop (Apred (Auntaint taint_info, [exp]))
  | _ ->
      if !Config.footprint then
        let taint_info = { PredSymb.taint_source = callee_pname; taint_kind; } in
        (* add untained(n_lexp) to the footprint *)
        Attribute.add tenv ~footprint:true prop (Auntaint taint_info) [exp]
      else prop

(** execute a call for an unknown or scan function *)
and unknown_or_scan_call ~is_scan ret_type_option ret_annots
    { Builtin.tenv; pdesc; prop_= pre; path; ret_ids;
      args; proc_name= callee_pname; loc; instr; } =
  let remove_file_attribute prop =
    let do_exp p (e, _) =
      let do_attribute q atom =
        match atom with
        | Sil.Apred ((Aresource {ra_res = Rfile} as res), _) -> Attribute.remove_for_attr tenv q res
        | _ -> q in
      IList.fold_left do_attribute p (Attribute.get_for_exp tenv p e) in
    let filtered_args =
      match args, instr with
      | _:: other_args, Sil.Call (_, _, _, _, { CallFlags.cf_virtual }) when cf_virtual ->
          (* Do not remove the file attribute on the reciver for virtual calls *)
          other_args
      | _ -> args in
    IList.fold_left do_exp prop filtered_args in
  let add_tainted_pre prop actuals caller_pname callee_pname =
    if Config.taint_analysis then
      match Taint.accepts_sensitive_params callee_pname None with
      | [] -> prop
      | param_nums ->
          let check_taint_if_nums_match (prop_acc, param_num) (actual_exp, _actual_typ) =
            let prop_acc' =
              try
                let _, taint_kind = IList.find (fun (num, _) -> num = param_num) param_nums in
                check_untainted tenv actual_exp taint_kind caller_pname callee_pname prop_acc
              with Not_found -> prop_acc in
            prop_acc', param_num + 1 in
          IList.fold_left
            check_taint_if_nums_match
            (prop, 0)
            actuals
          |> fst
    else prop in
  let actuals_by_ref =
    IList.flatten_options (IList.mapi
                             (fun i actual -> match actual with
                                | (Exp.Lvar _ as e, (Typ.Tptr _ as t)) -> Some (e, t, i)
                                | _ -> None)
                             args) in
  let has_nullable_annot = Annotations.ia_is_nullable ret_annots in
  let pre_final =
    (* in Java, assume that skip functions close resources passed as params *)
    let pre_1 =
      if Procname.is_java callee_pname
      then remove_file_attribute pre
      else pre in
    let pre_2 = match ret_ids, ret_type_option with
      | [ret_id], Some ret_typ ->
          add_constraints_on_retval tenv
            pdesc pre_1 (Exp.Var ret_id) ret_typ ~has_nullable_annot callee_pname loc
      | _ ->
          pre_1 in
    let pre_3 = add_constraints_on_actuals_by_ref tenv pre_2 actuals_by_ref callee_pname loc in
    let caller_pname = Cfg.Procdesc.get_proc_name pdesc in
    add_tainted_pre pre_3 args caller_pname callee_pname in
  if is_scan (* if scan function, don't mark anything with undef attributes *)
  then [(Tabulation.remove_constant_string_class tenv pre_final, path)]
  else
    (* otherwise, add undefined attribute to retvals and actuals passed by ref *)
    let exps_to_mark =
      let ret_exps = IList.map (fun ret_id -> Exp.Var ret_id) ret_ids in
      IList.fold_left
        (fun exps_to_mark (exp, _, _) -> exp :: exps_to_mark) ret_exps actuals_by_ref in
    let prop_with_undef_attr =
      let path_pos = State.get_path_pos () in
      Attribute.mark_vars_as_undefined tenv
        pre_final exps_to_mark callee_pname ret_annots loc path_pos in
    [(prop_with_undef_attr, path)]

and check_variadic_sentinel
    ?(fails_on_nil = false) n_formals  (sentinel, null_pos)
    { Builtin.pdesc; tenv; prop_; path; args; proc_name; loc; }
  =
  (* from clang's lib/Sema/SemaExpr.cpp: *)
  (* "nullPos" is the number of formal parameters at the end which *)
  (* effectively count as part of the variadic arguments.  This is *)
  (* useful if you would prefer to not have *any* formal parameters, *)
  (* but the language forces you to have at least one. *)
  let first_var_arg_pos = if null_pos > n_formals then 0 else n_formals - null_pos in
  let nargs = IList.length args in
  (* sentinels start counting from the last argument to the function *)
  let sentinel_pos = nargs - sentinel - 1 in
  let mk_non_terminal_argsi (acc, i) a =
    if i < first_var_arg_pos || i >= sentinel_pos then (acc, i +1)
    else ((a, i):: acc, i +1) in
  (* IList.fold_left reverses the arguments *)
  let non_terminal_argsi = fst (IList.fold_left mk_non_terminal_argsi ([], 0) args) in
  let check_allocated result ((lexp, typ), i) =
    (* simulate a Load for [lexp] *)
    let tmp_id_deref = Ident.create_fresh Ident.kprimed in
    let load_instr = Sil.Load (tmp_id_deref, lexp, typ, loc) in
    try
      instrs tenv pdesc [load_instr] result
    with e when SymOp.exn_not_failure e ->
      if not fails_on_nil then
        let deref_str = Localise.deref_str_nil_argument_in_variadic_method proc_name nargs i in
        let err_desc =
          Errdesc.explain_dereference tenv ~use_buckets: true ~is_premature_nil: true
            deref_str prop_ loc in
        raise (Exceptions.Premature_nil_termination (err_desc, __POS__))
      else
        raise e in
  (* IList.fold_left reverses the arguments back so that we report an *)
  (* error on the first premature nil argument *)
  IList.fold_left check_allocated [(prop_, path)] non_terminal_argsi

and check_variadic_sentinel_if_present
    ({ Builtin.prop_; path; proc_name; } as builtin_args) =
  match Specs.proc_resolve_attributes proc_name with
  | None ->
      [(prop_, path)]
  | Some callee_attributes ->
      match PredSymb.get_sentinel_func_attribute_value
              callee_attributes.ProcAttributes.func_attributes with
      | None -> [(prop_, path)]
      | Some sentinel_arg ->
          let formals = callee_attributes.ProcAttributes.formals in
          check_variadic_sentinel (IList.length formals) sentinel_arg builtin_args

and sym_exec_objc_getter field_name ret_typ tenv ret_ids pdesc pname loc args prop =
  L.d_strln ("No custom getter found. Executing the ObjC builtin getter with ivar "^
             (Ident.fieldname_to_string field_name)^".");
  let ret_id =
    match ret_ids with
    | [ret_id] -> ret_id
    | _ -> assert false in
  match args with
  | [(lexp, typ)] ->
      let typ' = (match Tenv.expand_type tenv typ with
          | Typ.Tstruct _ as s -> s
          | Typ.Tptr (t, _) -> Tenv.expand_type tenv t
          | _ -> assert false) in
      let field_access_exp = Exp.Lfield (lexp, field_name, typ') in
      execute_load
        ~report_deref_errors:false pname pdesc tenv ret_id field_access_exp ret_typ loc prop
  | _ -> raise (Exceptions.Wrong_argument_number __POS__)

and sym_exec_objc_setter field_name _ tenv _ pdesc pname loc args prop =
  L.d_strln ("No custom setter found. Executing the ObjC builtin setter with ivar "^
             (Ident.fieldname_to_string field_name)^".");
  match args with
  | (lexp1, typ1) :: (lexp2, typ2)::_ ->
      let typ1' = (match Tenv.expand_type tenv typ1 with
          | Typ.Tstruct _ as s -> s
          | Typ.Tptr (t, _) -> Tenv.expand_type tenv t
          | _ -> assert false) in
      let field_access_exp = Exp.Lfield (lexp1, field_name, typ1') in
      execute_store ~report_deref_errors:false pname pdesc tenv field_access_exp typ2 lexp2 loc prop
  | _ -> raise (Exceptions.Wrong_argument_number __POS__)

and sym_exec_objc_accessor property_accesor ret_typ tenv ret_ids pdesc _ loc args prop path
  : Builtin.ret_typ =
  let f_accessor =
    match property_accesor with
    | ProcAttributes.Objc_getter field_name -> sym_exec_objc_getter field_name
    | ProcAttributes.Objc_setter field_name -> sym_exec_objc_setter field_name in
  (* we want to execute in the context of the current procedure, not in the context of callee_pname,
     since this is the procname of the setter/getter method *)
  let cur_pname = Cfg.Procdesc.get_proc_name pdesc in
  f_accessor ret_typ tenv ret_ids pdesc cur_pname loc args prop
  |> IList.map (fun p -> (p, path))

(** Perform symbolic execution for a function call *)
and proc_call summary {Builtin.pdesc; tenv; prop_= pre; path; ret_ids; args= actual_pars; loc; } =
  let caller_pname = Cfg.Procdesc.get_proc_name pdesc in
  let callee_pname = Specs.get_proc_name summary in
  let ret_typ = Specs.get_ret_type summary in
  let check_return_value_ignored () =
    (* check if the return value of the call is ignored, and issue a warning *)
    let is_ignored = match ret_typ, ret_ids with
      | Typ.Tvoid, _ -> false
      | Typ.Tint _, _ when not (proc_is_defined callee_pname) ->
          (* if the proc returns Tint and is not defined, *)
          (* don't report ignored return value *)
          false
      | _, [] -> true
      | _, [id] -> Errdesc.id_is_assigned_then_dead (State.get_node ()) id
      | _ -> false in
    if is_ignored
    && Specs.get_flag callee_pname proc_flag_ignore_return = None then
      let err_desc = Localise.desc_return_value_ignored callee_pname loc in
      let exn = (Exceptions.Return_value_ignored (err_desc, __POS__)) in
      let pre_opt = State.get_normalized_pre (Abs.abstract_no_symop caller_pname) in
      Reporting.log_warning caller_pname ?pre:pre_opt exn in
  check_inherently_dangerous_function caller_pname callee_pname;
  begin
    let formal_types = IList.map (fun (_, typ) -> typ) (Specs.get_formals summary) in
    let rec comb actual_pars formal_types =
      match actual_pars, formal_types with
      | [], [] -> actual_pars
      | (e, t_e):: etl', _:: tl' ->
          (e, t_e) :: comb etl' tl'
      | _,[] ->
          Errdesc.warning_err
            (State.get_loc ())
            "likely use of variable-arguments function, or function prototype missing@.";
          L.d_warning
            "likely use of variable-arguments function, or function prototype missing";
          L.d_ln();
          L.d_str "actual parameters: "; Sil.d_exp_list (IList.map fst actual_pars); L.d_ln ();
          L.d_str "formal parameters: "; Typ.d_list formal_types; L.d_ln ();
          actual_pars
      | [], _ ->
          L.d_str ("**** ERROR: Procedure " ^ Procname.to_string callee_pname);
          L.d_strln (" mismatch in the number of parameters ****");
          L.d_str "actual parameters: "; Sil.d_exp_list (IList.map fst actual_pars); L.d_ln ();
          L.d_str "formal parameters: "; Typ.d_list formal_types; L.d_ln ();
          raise (Exceptions.Wrong_argument_number __POS__) in
    let actual_params = comb actual_pars formal_types in
    (* Actual parameters are associated to their formal
       parameter type if there are enough formal parameters, and
       to their actual type otherwise. The latter case happens
       with variable - arguments functions *)
    check_return_value_ignored ();
    (* In case we call an objc instance method we add and extra spec *)
    (* were the receiver is null and the semantics of the call is nop*)
    let callee_attrs = Specs.get_attributes summary in
    if (!Config.curr_language <> Config.Java)  &&
       (Specs.get_attributes summary).ProcAttributes.is_objc_instance_method then
      handle_objc_instance_method_call actual_pars actual_params pre tenv ret_ids pdesc
        callee_pname loc path (Tabulation.exe_function_call callee_attrs)
    else  (* non-objective-c method call. Standard tabulation *)
      Tabulation.exe_function_call
        callee_attrs tenv ret_ids pdesc callee_pname loc actual_params pre path
  end

(** perform symbolic execution for a single prop, and check for junk *)
and sym_exec_wrapper handle_exn tenv pdesc instr ((prop: Prop.normal Prop.t), path)
  : Paths.PathSet.t =
  let pname = Cfg.Procdesc.get_proc_name pdesc in
  let prop_primed_to_normal p = (* Rename primed vars with fresh normal vars, and return them *)
    let fav = Prop.prop_fav p in
    Sil.fav_filter_ident fav Ident.is_primed;
    let ids_primed = Sil.fav_to_list fav in
    let ids_primed_normal =
      IList.map (fun id -> (id, Ident.create_fresh Ident.knormal)) ids_primed in
    let ren_sub =
      Sil.sub_of_list (IList.map
                         (fun (id1, id2) -> (id1, Exp.Var id2)) ids_primed_normal) in
    let p' = Prop.normalize tenv (Prop.prop_sub ren_sub p) in
    let fav_normal = Sil.fav_from_list (IList.map snd ids_primed_normal) in
    p', fav_normal in
  let prop_normal_to_primed fav_normal p = (* rename given normal vars to fresh primed *)
    if Sil.fav_to_list fav_normal = [] then p
    else Prop.exist_quantify tenv fav_normal p in
  try
    let pre_process_prop p =
      let p', fav =
        if Sil.instr_is_auxiliary instr
        then p, Sil.fav_new ()
        else prop_primed_to_normal p in
      let p'' =
        let map_res_action e ra = (* update the vpath in resource attributes *)
          let vpath, _ = Errdesc.vpath_find tenv p' e in
          { ra with PredSymb.ra_vpath = vpath } in
        Attribute.map_resource tenv p' map_res_action in
      p'', fav in
    let post_process_result fav_normal p path =
      let p' = prop_normal_to_primed fav_normal p in
      State.set_path path None;
      let node_has_abstraction node =
        let instr_is_abstraction = function
          | Sil.Abstract _ -> true
          | _ -> false in
        IList.exists instr_is_abstraction (Cfg.Node.get_instrs node) in
      let curr_node = State.get_node () in
      match Cfg.Node.get_kind curr_node with
      | Cfg.Node.Prune_node _ when not (node_has_abstraction curr_node) ->
          (* don't check for leaks in prune nodes, unless there is abstraction anyway,*)
          (* but force them into either branch *)
          p'
      | _ ->
          check_deallocate_static_memory (Abs.abstract_junk ~original_prop: p pname tenv p') in
    L.d_str "Instruction "; Sil.d_instr instr; L.d_ln ();
    let prop', fav_normal = pre_process_prop prop in
    let res_list =
      Config.run_with_abs_val_equal_zero (* no exp abstraction during sym exe *)
        (fun () -> sym_exec tenv pdesc instr prop' path)
        () in
    let res_list_nojunk =
      IList.map
        (fun (p, path) -> (post_process_result fav_normal p path, path))
        res_list in
    let results =
      IList.map
        (fun (p, path) -> (Prop.prop_rename_primed_footprint_vars tenv p, path))
        res_list_nojunk in
    L.d_strln "Instruction Returns";
    Propgraph.d_proplist prop (IList.map fst results); L.d_ln ();
    State.mark_instr_ok ();
    Paths.PathSet.from_renamed_list results
  with exn when Exceptions.handle_exception exn && !Config.footprint ->
    handle_exn exn; (* calls State.mark_instr_fail *)
    if Config.nonstop
    then
      (* in nonstop mode treat the instruction as skip *)
      (Paths.PathSet.from_renamed_list [(prop, path)])
    else
      Paths.PathSet.empty

(** {2 Lifted Abstract Transfer Functions} *)

let node handle_exn tenv node (pset : Paths.PathSet.t) : Paths.PathSet.t =
  let pdesc = Cfg.Node.get_proc_desc node in
  let pname = Cfg.Procdesc.get_proc_name pdesc in
  let exe_instr_prop instr p tr (pset1: Paths.PathSet.t) =
    let pset2 =
      if Tabulation.prop_is_exn pname p && not (Sil.instr_is_auxiliary instr)
         && Cfg.Node.get_kind node <> Cfg.Node.exn_handler_kind
         (* skip normal instructions if an exception was thrown,
            unless this is an exception handler node *)
      then
        begin
          L.d_str "Skipping instr "; Sil.d_instr instr; L.d_strln " due to exception";
          Paths.PathSet.from_renamed_list [(p, tr)]
        end
      else sym_exec_wrapper handle_exn tenv pdesc instr (p, tr) in
    Paths.PathSet.union pset2 pset1 in
  let exe_instr_pset pset instr =
    Paths.PathSet.fold (exe_instr_prop instr) pset Paths.PathSet.empty in
  IList.fold_left exe_instr_pset pset (Cfg.Node.get_instrs node)
