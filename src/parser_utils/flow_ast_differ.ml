(**
 * Copyright (c) 2014, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast = Flow_ast
open Utils_js

type 'a change' =
  | Replace of 'a * 'a
  | Insert of 'a list
  | Delete of 'a

type 'a change = (Loc.t * 'a change')

type diff_algorithm = Trivial | Standard

(* Position in the list is necessary to figure out what Loc.t to assign to insertions. *)
type 'a diff_result = (int (* position *) * 'a change')

(* diffs based on identity *)
(* return None if no good diff was found (max edit distance exceeded, etc.) *)
let trivial_list_diff (old_list : 'a list) (new_list : 'a list) : ('a diff_result list) option =
 (* inspect the lists pairwise and record any items which are different as replacements. Give up if
  * the lists have different lengths.*)
  let rec helper i lst1 lst2 =
    match lst1, lst2 with
    | [], [] -> Some []
    | hd1::tl1, hd2::tl2 ->
      let rest = helper (i + 1) tl1 tl2 in
      if hd1 != hd2 then
        Option.map rest ~f:(List.cons (i, Replace (hd1, hd2)))
      else
        rest
    | _, []
    | [], _ ->
      None
  in
  if old_list == new_list then Some []
  else helper 0 old_list new_list

(* diffs based on http://www.xmailserver.org/diff2.pdf on page 6 *)
let standard_list_diff (old_list : 'a list) (new_list : 'a list) : ('a diff_result list) option =
  (* Lots of acccesses in this algorithm so arrays are faster *)
  let (old_arr, new_arr) = Array.of_list old_list, Array.of_list new_list in
  let (n, m) = Array.length old_arr, Array.length new_arr in

  (* The shortest edit sequence problem is equivalent to finding the longest
     common subsequence, or equivalently the longest trace *)
  let longest_trace max_distance : (int * int) list option =
    (* adds the match points in this snake to the trace and produces the endpoint along with the
       new trace *)
    let rec follow_snake x y trace =
      if x >= n || y >= m then x, y, trace else
      if old_arr.(x) == new_arr.(y) then follow_snake (x + 1) (y + 1) ((x,y) :: trace) else
      x, y, trace in

    let rec build_trace dist frontier visited  =
      if Hashtbl.mem visited (n, m) then () else
      let new_frontier = Queue.create () in
      if dist > max_distance then () else

      let follow_trace (x, y) : unit =
        let trace = Hashtbl.find visited (x,y) in
        let x_old, y_old, advance_in_old_list = follow_snake (x + 1) y trace in
        let x_new, y_new, advance_in_new_list = follow_snake x (y + 1) trace in
        (* if we have already visited this location, there is a shorter path to it, so we don't
           store this trace *)
        let () = if Hashtbl.mem visited (x_old, y_old) |> not then
            let () = Queue.add (x_old, y_old) new_frontier in
            Hashtbl.add visited (x_old, y_old) advance_in_old_list in
        if Hashtbl.mem visited (x_new, y_new) |> not then
            let () = Queue.add (x_new, y_new) new_frontier in
            Hashtbl.add visited (x_new, y_new) advance_in_new_list in

      Queue.iter follow_trace frontier;
      build_trace (dist + 1) new_frontier visited in

    (* Keep track of all visited string locations so we don't duplicate work *)
    let visited = Hashtbl.create (n * m) in
    let frontier = Queue.create () in
    (* Start with the basic trace, but follow a starting snake to a non-match point *)
    let x,y,trace = follow_snake 0 0 [] in
    Queue.add (x,y) frontier;
    Hashtbl.add visited (x,y) trace;
    build_trace 0 frontier visited;
    Hashtbl.find_opt visited (n,m) in

  (* Produces an edit script from a trace via the procedure described on page 4
     of the paper. Assumes the trace is ordered by the x coordinate *)
  let build_script_from_trace (trace : (int * int) list) : 'a diff_result list =

    (* adds inserts at position x_k for values in new_list from
       y_k + 1 to y_(k + 1) - 1 for k such that y_k + 1 < y_(k + 1) *)
    let rec add_inserts k script =
      let trace_len = List.length trace in
      let trace_array = Array.of_list trace in
      let gen_inserts first last =
        let len = last - first in
        Core_list.sub new_list ~pos:first ~len:len in
      if k > trace_len - 1 then script else
      (* The algorithm treats the trace as though (-1,-1) were the (-1)th match point
         in the list and (n,m) were the (len+1)th *)
      let first = if k = -1 then 0 else (trace_array.(k) |> snd) + 1 in
      let last = if k = trace_len - 1 then m else trace_array.(k + 1) |> snd in
      if first < last then
        let start = if k = -1 then -1 else trace_array.(k) |> fst in
        (start, Insert (gen_inserts first last)) :: script
        |> add_inserts (k + 1)
      else add_inserts (k + 1) script in

    let change_compare (pos1, chg1) (pos2, chg2) =
      if pos1 <> pos2 then compare pos1 pos2 else
      (* Orders the change types alphabetically. This puts same-indexed inserts before deletes *)
      match chg1, chg2 with
      | Insert _, Delete _ | Delete _, Replace _ | Insert _, Replace _ -> -1
      | Delete _, Insert _ | Replace _, Delete _ | Replace _, Insert _ -> 1
      | _ -> 0 in

    (* Convert like-indexed deletes and inserts into a replacement. This relies
       on the fact that sorting the script with our change_compare function will order all
       Insert nodes before Deletes *)
    let rec convert_to_replace script =
      match script with
      | [] | [_] -> script
      | (i1, Insert (x :: [])) :: (i2, Delete y) :: t when i1 = i2 - 1 ->
          (i2, Replace (y, x)) :: (convert_to_replace t)
      | (i1, Insert (x :: rst)) :: (i2, Delete y) :: t when i1 = i2 - 1 ->
          (* We are only removing the first element of the insertion *)
          (i2, Replace (y, x)) :: (convert_to_replace ((i2, Insert rst) :: t))
      | h :: t -> h :: (convert_to_replace t) in

    (* Deletes are added for every element of old_list that does not have a
       match point with new_list *)
    let deletes =
      List.map fst trace
      |> ISet.of_list
      |> ISet.diff (ListUtils.range 0 n |> ISet.of_list)
      |> ISet.elements
      |> List.map (fun pos -> (pos, Delete (old_arr.(pos)))) in

    deletes
    |> add_inserts (-1)
    |> List.sort change_compare
    |> convert_to_replace in

  let open Option in
  longest_trace (n + m)
  >>| List.rev (* trace is built backwards for efficiency *)
  >>| build_script_from_trace

let list_diff = function
  | Trivial -> trivial_list_diff
  | Standard -> standard_list_diff

(* We need a variant here for every node that we want to be able to store a diff for. The more we
 * have here, the more granularly we can diff. *)
type node =
  | Statement of (Loc.t, Loc.t) Ast.Statement.t
  | Program of (Loc.t, Loc.t) Ast.program
  | Expression of (Loc.t, Loc.t) Ast.Expression.t
  | Identifier of Loc.t Ast.Identifier.t
  | Pattern of (Loc.t, Loc.t) Ast.Pattern.t
  | TypeAnnotation of (Loc.t, Loc.t) Flow_ast.Type.annotation
  | ClassProperty of (Loc.t, Loc.t) Flow_ast.Class.Property.t
  | ObjectProperty of (Loc.t, Loc.t) Flow_ast.Expression.Object.property

(* This is needed because all of the functions assume that if they are called, there is some
 * difference between their arguments and they will often report that even if no difference actually
 * exists. This allows us to easily avoid calling the diffing function if there is no difference. *)
let diff_if_changed f x1 x2 =
  if x1 == x2 then [] else f x1 x2

let diff_if_changed_opt f opt1 opt2: node change list option =
  match opt1, opt2 with
  | Some x1, Some x2 ->
    if x1 == x2 then Some [] else f x1 x2
  | None, None ->
    Some []
  | _ ->
    None

(* This is needed if the function f takes its arguments as options and produces an optional
   node change list (for instance, type annotation). In this case it is not sufficient just to
   give up and return None if only one of the options is present *)
let diff_if_changed_opt_arg f opt1 opt2: node change list option =
  match opt1, opt2 with
  | None, None -> Some []
  | Some x1, Some x2 when x1 == x2 -> Some []
  | _ -> f opt1 opt2

(* This is needed if the function for the given node returns a node change
* list instead of a node change list option (for instance, expression) *)
let diff_if_changed_nonopt_fn f opt1 opt2: node change list option =
  match opt1, opt2 with
  | Some x1, Some x2 ->
    if x1 == x2 then Some [] else Some (f x1 x2)
  | None, None ->
    Some []
  | _ ->
    None

(* Outline:
* - There is a function for every AST node that we want to be able to recurse into.
* - Each function for an AST node represented in the `node` type above should return a list of
*   changes.
*   - If it cannot compute a more granular diff, it should return a list with a single element,
*     which records the replacement of `old_node` with `new_node` (where `old_node` and
*     `new_node` are the arguments passed to that function)
* - Every other function should do the same, except if it is unable to return a granular diff, it
*   should return `None` to indicate that its parent must be recorded as a replacement. This is
*   because there is no way to record a replacement for a node which does not appear in the
*   `node` type above.
* - We can add additional functions as needed to improve the granularity of the diffs.
* - We could eventually reach a point where no function would ever fail to generate a diff. That
*   would require us to implement a function here for every AST node, and add a variant to the
*   `node` type for every AST node as well. It would also likely require some tweaks to the AST.
*   For example, a function return type is optional. If it is None, it has no location attached.
*   What would we do if the original tree had no annotation, but the new tree did have one? We
*   would not know what Loc.t to give to the insertion.
*)
(* Entry point *)
let program (algo : diff_algorithm)
            (program1: (Loc.t, Loc.t) Ast.program)
            (program2: (Loc.t, Loc.t) Ast.program) : node change list =

  (* Runs `list_diff` and then recurses into replacements (using `f`) to get more granular diffs.
     For inserts and deletes, it uses `trivial` to produce a Loc.t and a b for the change *)
  let diff_and_recurse (type a) (type b)
      (f: a -> a -> b change list option)
      (trivial : a -> (Loc.t * b) option)
      (old_list: a list)
      (new_list: a list)
      : b change list option =
    let open Option in

    let recurse_into_change = function
      | _, Replace (x1, x2) -> f x1 x2
      | index, Insert lst ->
        let loc =
          if List.length old_list = 0 then None else
          (* To insert at the start of the list, insert before the first element *)
          if index = -1 then List.hd old_list |> trivial >>| fst >>| Loc.start_loc
          (* Otherwise insert it after the current element *)
          else List.nth old_list index |> trivial >>| fst >>| Loc.end_loc in
        List.map trivial lst
        |>  all
        >>| List.map snd (* drop the loc *)
        >>| (fun x -> Insert x)
        |>  both loc
        >>| Core_list.return
      | _, Delete x ->
        trivial x
        >>| (fun (loc, y) -> loc, Delete y)
        >>| Core_list.return in

    let recurse_into_changes =
      List.map recurse_into_change
      %> all
      %> map ~f:List.concat in

    list_diff algo old_list new_list
    >>= recurse_into_changes in

  (* diff_and_recurse for when there is no way to get a trivial transfomation from a to b*)
  let diff_and_recurse_no_trivial f = diff_and_recurse f (fun _ -> None) in

  let rec program' (program1: (Loc.t, Loc.t) Ast.program) (program2: (Loc.t, Loc.t) Ast.program) : node change list =
    let (program_loc, statements1, _) = program1 in
    let (_, statements2, _) = program2 in
    statement_list statements1 statements2
    |> Option.value ~default:[(program_loc, Replace (Program program1, Program program2))]

  and statement_list (stmts1: (Loc.t, Loc.t) Ast.Statement.t list) (stmts2: (Loc.t, Loc.t) Ast.Statement.t list)
      : node change list option =
    diff_and_recurse (fun x y -> Some (statement x y))
      (fun s -> Some (Ast_utils.loc_of_statement s, Statement s)) stmts1 stmts2

  and statement (stmt1: (Loc.t, Loc.t) Ast.Statement.t) (stmt2: (Loc.t, Loc.t) Ast.Statement.t)
      : node change list =
    let open Ast.Statement in
    let changes = match stmt1, stmt2 with
    | (_, VariableDeclaration var1), (_, VariableDeclaration var2) ->
      variable_declaration var1 var2
    | (_, FunctionDeclaration func1), (_, FunctionDeclaration func2) ->
      function_declaration func1 func2
    | (_, ClassDeclaration class1), (_, ClassDeclaration class2) ->
      class_ class1 class2
    | (_, Ast.Statement.If if1), (_, Ast.Statement.If if2) ->
      if_statement if1 if2
    | (_, Ast.Statement.Expression expr1), (_, Ast.Statement.Expression expr2) ->
      expression_statement expr1 expr2
    | (_, Ast.Statement.Block block1), (_, Ast.Statement.Block block2) ->
      block block1 block2
    | (_, Ast.Statement.For for1), (_, Ast.Statement.For for2) ->
      for_statement for1 for2
    | (_, Ast.Statement.ForIn for_in1), (_, Ast.Statement.ForIn for_in2) ->
      for_in_statement for_in1 for_in2
    | (_, Ast.Statement.While while1), (_, Ast.Statement.While while2) ->
      Some (while_statement while1 while2)
    | (_, Ast.Statement.ForOf for_of1), (_, Ast.Statement.ForOf for_of2) ->
      for_of_statement for_of1 for_of2
    | (_, Ast.Statement.DoWhile do_while1), (_, Ast.Statement.DoWhile do_while2) ->
      Some (do_while_statement do_while1 do_while2)
    | (_, Ast.Statement.Switch switch1), (_, Ast.Statement.Switch switch2) ->
      switch_statement switch1 switch2
    | (_, Ast.Statement.Return return1), (_, Ast.Statement.Return return2) ->
      return_statement return1 return2
    | (_, Ast.Statement.With with1), (_, Ast.Statement.With with2) ->
      Some (with_statement with1 with2)
    | (_, Ast.Statement.ExportDefaultDeclaration export1),
      (_, Ast.Statement.ExportDefaultDeclaration export2) ->
      export_default_declaration export1 export2
    | (_, Ast.Statement.DeclareExportDeclaration export1),
      (_, Ast.Statement.DeclareExportDeclaration export2) ->
      declare_export export1 export2
    | (_, Ast.Statement.ExportNamedDeclaration export1),
      (_, Ast.Statement.ExportNamedDeclaration export2) ->
      export_named_declaration export1 export2
    | _, _ ->
      None
    in
    let old_loc = Ast_utils.loc_of_statement stmt1 in
    Option.value changes ~default:[(old_loc, Replace (Statement stmt1, Statement stmt2))]

  and export_named_declaration export1 export2 =
    let open Ast.Statement.ExportNamedDeclaration in
    let { declaration = decl1; specifiers = specs1; source = src1; exportKind = kind1 } = export1 in
    let { declaration = decl2; specifiers = specs2; source = src2; exportKind = kind2 } = export2 in
    if src1 != src2 || kind1 != kind2 then None else
    let decls = diff_if_changed_nonopt_fn statement decl1 decl2 in
    let specs = diff_if_changed_opt export_named_declaration_specifier specs1 specs2 in
    Option.(all [decls; specs] >>| List.concat)

  and export_default_declaration (export1 : (Loc.t, Loc.t) Ast.Statement.ExportDefaultDeclaration.t)
                                 (export2 : (Loc.t, Loc.t) Ast.Statement.ExportDefaultDeclaration.t)
      : node change list option =
    let open Ast.Statement.ExportDefaultDeclaration in
    let { declaration = declaration1; default = default1 } = export1 in
    let { declaration = declaration2; default = default2 } = export2 in
    if default1 != default2 then None else
    match declaration1, declaration2 with
    | Declaration s1, Declaration s2 -> statement s1 s2 |> Option.return
    | Ast.Statement.ExportDefaultDeclaration.Expression e1,
      Ast.Statement.ExportDefaultDeclaration.Expression e2 ->
        expression e1 e2 |> Option.return
    | _ -> None

  and export_specifier (spec1 : Loc.t Ast.Statement.ExportNamedDeclaration.ExportSpecifier.t)
      (spec2 : Loc.t Ast.Statement.ExportNamedDeclaration.ExportSpecifier.t)
      : node change list option =
    let open Ast.Statement.ExportNamedDeclaration.ExportSpecifier in
    let _, { local = local1; exported = exported1 } = spec1 in
    let _, { local = local2; exported = exported2 } = spec2 in
    let locals = diff_if_changed identifier local1 local2 in
    let exporteds = diff_if_changed_nonopt_fn identifier exported1 exported2 in
    Option.(all [return locals; exporteds] >>| List.concat)

  and export_named_declaration_specifier
      (specs1 : Loc.t Ast.Statement.ExportNamedDeclaration.specifier)
      (specs2 : Loc.t Ast.Statement.ExportNamedDeclaration.specifier) =
    let open Ast.Statement.ExportNamedDeclaration in
    match specs1, specs2 with
    | ExportSpecifiers es1, ExportSpecifiers es2 ->
      diff_and_recurse_no_trivial export_specifier es1 es2
    | ExportBatchSpecifier (_, ebs1), ExportBatchSpecifier (_, ebs2) ->
      diff_if_changed_nonopt_fn identifier ebs1 ebs2
    | _ -> None

  and declare_export (export1 : (Loc.t, Loc.t) Ast.Statement.DeclareExportDeclaration.t)
                                 (export2 : (Loc.t, Loc.t) Ast.Statement.DeclareExportDeclaration.t)
      : node change list option =
    let open Ast.Statement.DeclareExportDeclaration in
    let { default = default1; declaration = decl1; specifiers = specs1; source = src1 } = export1 in
    let { default = default2; declaration = decl2; specifiers = specs2; source = src2 } = export2 in
    if default1 != default2 || src1 != src2 || decl1 != decl2 then None else
    diff_if_changed_opt export_named_declaration_specifier specs1 specs2

  and function_declaration func1 func2 = function_ func1 func2

  and function_ (func1: (Loc.t, Loc.t) Ast.Function.t) (func2: (Loc.t, Loc.t) Ast.Function.t)
      : node change list option =
    let open Ast.Function in
    let {
      id = id1; params = params1; body = body1; async = async1; generator = generator1;
      expression = expression1; predicate = predicate1; return = return1; tparams = tparams1;
    } = func1 in
    let {
      id = id2; params = params2; body = body2; async = async2; generator = generator2;
      expression = expression2; predicate = predicate2; return = return2; tparams = tparams2;
    } = func2 in

    if id1 != id2 || params1 != params2 || (* body handled below *) async1 != async2
        || generator1 != generator2 || expression1 != expression2 || predicate1 != predicate2
        || tparams1 != tparams2
    then
      None
    else
      let fnbody = diff_if_changed_opt function_body_any (Some body1) (Some body2) in
      let returns = diff_if_changed return_type_annotation return1 return2 |> Option.return in
      Option.(all [fnbody; returns] >>| List.concat)

  and function_body_any (body1 : (Loc.t, Loc.t) Ast.Function.body)
                        (body2 : (Loc.t, Loc.t) Ast.Function.body)
      : node change list option =
    let open Ast.Function in
    match body1, body2 with
    | BodyExpression e1, BodyExpression e2 -> expression e1 e2 |> Option.return
    | BodyBlock (_, block1), BodyBlock (_, block2) -> block block1 block2
    | _ -> None

  and return_type_annotation (return1: (Loc.t, Loc.t) Ast.Function.return)
                      (return2: (Loc.t, Loc.t) Ast.Function.return)
      : node change list =
    let open Ast.Function in
    match return1, return2 with
    | Missing _, Missing _ -> []
    | Missing loc1, Available (loc2, typ) -> [loc1, Insert [TypeAnnotation (loc2, typ)]]
    | Available (loc1, typ), Missing _ -> [loc1, Delete (TypeAnnotation (loc1, typ))]
    | Available (loc1, typ1), Available (loc2, typ2) ->
     [loc1, Replace (TypeAnnotation (loc1, typ1), TypeAnnotation (loc2, typ2))]

  and variable_declarator (decl1: (Loc.t, Loc.t) Ast.Statement.VariableDeclaration.Declarator.t) (decl2: (Loc.t, Loc.t) Ast.Statement.VariableDeclaration.Declarator.t)
      : node change list option =
    let open Ast.Statement.VariableDeclaration.Declarator in
    let (_, { id = id1; init = init1 }) = decl1 in
    let (_, { id = id2; init = init2 }) = decl2 in
    if id1 != id2 then
      Some (pattern id1 id2)
    else
      diff_if_changed_nonopt_fn expression init1 init2

  and variable_declaration (var1: (Loc.t, Loc.t) Ast.Statement.VariableDeclaration.t) (var2: (Loc.t, Loc.t) Ast.Statement.VariableDeclaration.t)
      : node change list option =
    let open Ast.Statement.VariableDeclaration in
    let { declarations = declarations1; kind = kind1 } = var1 in
    let { declarations = declarations2; kind = kind2 } = var2 in
    if kind1 != kind2 then
      None
    else if declarations1 != declarations2 then
      diff_and_recurse_no_trivial variable_declarator declarations1 declarations2
    else
      Some []

  and if_statement (if1: (Loc.t, Loc.t) Ast.Statement.If.t) (if2: (Loc.t, Loc.t) Ast.Statement.If.t)
      : node change list option =
    let open Ast.Statement.If in
    let {
      test = test1;
      consequent = consequent1;
      alternate = alternate1
    } = if1 in
    let {
      test = test2;
      consequent = consequent2;
      alternate = alternate2
    } = if2 in

    let expr_diff = Some (diff_if_changed expression test1 test2) in
    let cons_diff = Some (diff_if_changed statement consequent1 consequent2) in
    let alt_diff = match alternate1, alternate2 with
      | None, None -> Some ([])
      | Some _, None
      | None, Some _ -> None
      | Some a1, Some a2 -> Some (diff_if_changed statement a1 a2) in
    let result_list = [expr_diff; cons_diff; alt_diff] in
    Option.all result_list |> Option.map ~f:List.concat

    and with_statement (with1: (Loc.t, Loc.t) Ast.Statement.With.t)
                       (with2: (Loc.t, Loc.t) Ast.Statement.With.t)
        : node change list =
      let open Ast.Statement.With in
      let {_object = _object1; body = body1;} = with1 in
      let {_object = _object2; body = body2;} = with2 in
      let _object_diff = diff_if_changed expression _object1 _object2 in
      let body_diff    = diff_if_changed statement  body1    body2    in
      _object_diff @ body_diff

  and class_ (class1: (Loc.t, Loc.t) Ast.Class.t) (class2: (Loc.t, Loc.t) Ast.Class.t) =
    let open Ast.Class in
    let {
      id=id1; body=body1; tparams=tparams1; extends=extends1;
      implements=implements1; classDecorators=classDecorators1;
    } = class1 in
    let {
      id=id2; body=body2; tparams=tparams2; extends=extends2;
      implements=implements2; classDecorators=classDecorators2;
    } = class2 in
    if id1 != id2 || (* body handled below *) tparams1 != tparams2 || extends1 != extends2 ||
        implements1 != implements2 || classDecorators1 != classDecorators2
    then
      None
    else
      (* just body changed *)
      class_body body1 body2

  and class_body (class_body1: (Loc.t, Loc.t) Ast.Class.Body.t) (class_body2: (Loc.t, Loc.t) Ast.Class.Body.t)
      : node change list option =
    let open Ast.Class.Body in
    let _, { body=body1 } = class_body1 in
    let _, { body=body2 } = class_body2 in
    diff_and_recurse_no_trivial class_element body1 body2

  and class_element (elem1: (Loc.t, Loc.t) Ast.Class.Body.element) (elem2: (Loc.t, Loc.t) Ast.Class.Body.element)
      : node change list option =
    let open Ast.Class.Body in
    match elem1, elem2 with
    | Method (_, m1), Method (_, m2) ->
      class_method m1 m2
    | Property p1, Property p2 ->
      class_property p1 p2 |> Option.return
    | _ -> None (* TODO *)

  and class_property prop1 prop2 : node change list =
    let open Ast.Class.Property in
    let loc1, { key = key1; value = val1; annot = annot1; static = s1; variance = var1} = prop1 in
    let _,    { key = key2; value = val2; annot = annot2; static = s2; variance = var2} = prop2 in
    (if key1 != key2 || s1 != s2 || var1 != var2 then None else
      let vals = diff_if_changed_nonopt_fn expression val1 val2 in
      let annots = diff_if_changed_opt_arg type_annotation annot1 annot2 in
      Option.(all [vals; annots] >>| List.concat))
    |> Option.value ~default:[(loc1, Replace (ClassProperty prop1, ClassProperty prop2))]

  and class_method
      (m1: (Loc.t, Loc.t) Ast.Class.Method.t')
      (m2: (Loc.t, Loc.t) Ast.Class.Method.t')
      : node change list option =
    let open Ast.Class.Method in
    let { kind = kind1; key = key1; value = (_loc, value1); static = static1; decorators = decorators1 } =
      m1
    in
    let { kind = kind2; key = key2; value = (_loc, value2); static = static2; decorators = decorators2 } =
      m2
    in
    if kind1 != kind2 || key1 != key2 || (* value handled below *) static1 != static2 ||
        decorators1 != decorators2
    then
      None
    else
      function_ value1 value2

  and block (block1: (Loc.t, Loc.t) Ast.Statement.Block.t) (block2: (Loc.t, Loc.t) Ast.Statement.Block.t)
      : node change list option =
    let open Ast.Statement.Block in
    let { body = body1 } = block1 in
    let { body = body2 } = block2 in
    statement_list body1 body2

  and expression_statement
      (stmt1: (Loc.t, Loc.t) Ast.Statement.Expression.t)
      (stmt2: (Loc.t, Loc.t) Ast.Statement.Expression.t)
      : node change list option =
    let open Ast.Statement.Expression in
    let { expression = expr1; directive = dir1 } = stmt1 in
    let { expression = expr2; directive = dir2 } = stmt2 in
    if dir1 != dir2 then
      None
    else
      Some (expression expr1 expr2)

  and expression (expr1: (Loc.t, Loc.t) Ast.Expression.t) (expr2: (Loc.t, Loc.t) Ast.Expression.t)
      : node change list =
    let changes =
      (* The open is here to avoid ambiguity with the use of the local `Expression` constructor
       * below *)
      let open Ast.Expression in
      match expr1, expr2 with
      | (_, Binary b1), (_, Binary b2) ->
        binary b1 b2
      | (_, Unary u1), (_, Unary u2) ->
        unary u1 u2
      | (_, Ast.Expression.Identifier id1), (_, Ast.Expression.Identifier id2) ->
        identifier id1 id2 |> Option.return
      | (_, New new1), (_, New new2) ->
        new_ new1 new2
      | (_, Call call1), (_, Call call2) ->
        call_ call1 call2
      | (_, Function f1), (_, Function f2) | (_, ArrowFunction f1), (_, ArrowFunction f2) ->
        function_ f1 f2
      | (_, Class class1), (_, Class class2) ->
        class_ class1 class2
      | (_, Assignment assn1), (_, Assignment assn2) ->
        assignment_ assn1 assn2
      | (_, Object obj1), (_, Object obj2) ->
        _object obj1 obj2
      | _, _ ->
        None
    in
    let old_loc = Ast_utils.loc_of_expression expr1 in
    Option.value changes ~default:[(old_loc, Replace (Expression expr1, Expression expr2))]

  and assignment_ (assn1: (Loc.t, Loc.t) Ast.Expression.Assignment.t)
                  (assn2: (Loc.t, Loc.t) Ast.Expression.Assignment.t)
      : node change list option =
    let open Ast.Expression.Assignment in
    let { operator = op1; left = pat1; right = exp1 } = assn1 in
    let { operator = op2; left = pat2; right = exp2 } = assn2 in
    if op1 != op2 then None else
    diff_if_changed pattern pat1 pat2 @ diff_if_changed expression exp1 exp2 |> Option.return

  and object_spread_property prop1 prop2 =
    let open Ast.Expression.Object.SpreadProperty in
    let { argument = arg1 } = prop1 in
    let { argument = arg2 } = prop2 in
    expression arg1 arg2

  and object_key key1 key2 =
    let open Ast.Expression.Object.Property in
    match key1, key2 with
    | Literal _, Literal _ -> (* TODO: recurse into literals *) None
    | Ast.Expression.Object.Property.Identifier i1, Ast.Expression.Object.Property.Identifier i2 ->
        identifier i1 i2 |> Option.return
    | Computed e1, Computed e2 -> expression e1 e2 |> Option.return
    | _, _ -> None

  and object_regular_property (_, prop1) (_, prop2) =
    let open Ast.Expression.Object.Property in
    match prop1, prop2 with
    | Init { shorthand = sh1; value = val1; key = key1 },
      Init { shorthand = sh2; value = val2; key = key2 } ->
        if sh1 != sh2 then None else
        let values = diff_if_changed expression val1 val2 |> Option.return in
        let keys = diff_if_changed_opt object_key (Some key1) (Some key2) in
        Option.(all [keys; values] >>| List.concat)
    | Set {value = val1; key = key1 }, Set { value = val2; key = key2 }
    | Method {value = val1; key = key1 }, Method { value = val2; key = key2 }
    | Get {value = val1; key = key1 }, Get { value = val2; key = key2 } ->
        let values = diff_if_changed_opt function_ (Some (snd val1)) (Some (snd val2)) in
        let keys = diff_if_changed_opt object_key (Some key1) (Some key2) in
        Option.(all [keys; values] >>| List.concat)
    | _ -> None

  and object_property prop1 prop2 =
    let open Ast.Expression.Object in
    match prop1, prop2 with
    | Property (loc, p1), Property p2 ->
      object_regular_property (loc, p1) p2
      |> Option.value ~default:[(loc, Replace (ObjectProperty prop1, ObjectProperty prop2))]
      |> Option.return
    | SpreadProperty (_, p1), SpreadProperty (_, p2) ->
        object_spread_property p1 p2 |> Option.return
    | _ -> None

  and _object obj1 obj2 =
    let open Ast.Expression.Object in
    let { properties = properties1 } = obj1 in
    let { properties = properties2 } = obj2 in
    diff_and_recurse_no_trivial object_property properties1 properties2

  and binary (b1: (Loc.t, Loc.t) Ast.Expression.Binary.t) (b2: (Loc.t, Loc.t) Ast.Expression.Binary.t): node change list option =
    let open Ast.Expression.Binary in
    let { operator = op1; left = left1; right = right1 } = b1 in
    let { operator = op2; left = left2; right = right2 } = b2 in
    if op1 != op2 then
      None
    else
      Some (diff_if_changed expression left1 left2 @ diff_if_changed expression right1 right2)

  and unary (u1: (Loc.t, Loc.t) Ast.Expression.Unary.t) (u2: (Loc.t, Loc.t) Ast.Expression.Unary.t): node change list option =
    let open Ast.Expression.Unary in
    let { operator = op1; argument = arg1; prefix = prefix1 } = u1 in
    let { operator = op2; argument = arg2; prefix = prefix2 } = u2 in
    if op1 != op2 || prefix1 != prefix2 then
      None
    else
      Some (expression arg1 arg2)

  and identifier (id1: Loc.t Ast.Identifier.t) (id2: Loc.t Ast.Identifier.t): node change list =
    let (old_loc, _) = id1 in
    [(old_loc, Replace (Identifier id1, Identifier id2))]

  and new_ (new1: (Loc.t, Loc.t) Ast.Expression.New.t) (new2: (Loc.t, Loc.t) Ast.Expression.New.t): node change list option =
    let open Ast.Expression.New in
    let { callee = callee1; targs = targs1; arguments = arguments1 } = new1 in
    let { callee = callee2; targs = targs2; arguments = arguments2 } = new2 in
    if targs1 != targs2 || arguments1 != arguments2 then
      (* TODO(nmote) recurse into targs and arguments *)
      None
    else
      Some (diff_if_changed expression callee1 callee2)

  and call_ (call1: (Loc.t, Loc.t) Ast.Expression.Call.t) (call2: (Loc.t, Loc.t) Ast.Expression.Call.t): node change list option =
    let open Ast.Expression.Call in
    let { callee = callee1; targs = targs1; arguments = arguments1 } = call1 in
    let { callee = callee2; targs = targs2; arguments = arguments2 } = call2 in
    if targs1 != targs2 || arguments1 != arguments2 then
      (* TODO(nmote) recurse into targs and arguments *)
      None
    else
      Some (diff_if_changed expression callee1 callee2)

  and for_statement (stmt1: (Loc.t, Loc.t) Ast.Statement.For.t)
                    (stmt2: (Loc.t, Loc.t) Ast.Statement.For.t)
      : node change list option =
    let open Ast.Statement.For in
    let { init = init1; test = test1; update = update1; body = body1 } = stmt1 in
    let { init = init2; test = test2; update = update2; body = body2 } = stmt2 in
    let init = diff_if_changed_opt for_statement_init init1 init2 in
    let test = diff_if_changed_nonopt_fn expression test1 test2 in
    let update = diff_if_changed_nonopt_fn expression update1 update2 in
    let body = Some (diff_if_changed statement body1 body2) in
    Option.all [init; test; update; body] |> Option.map ~f:List.concat

  and for_statement_init(init1: (Loc.t, Loc.t) Ast.Statement.For.init)
                        (init2: (Loc.t, Loc.t) Ast.Statement.For.init)
      : node change list option =
    let open Ast.Statement.For in
    match (init1, init2) with
    | (InitDeclaration(_, decl1), InitDeclaration(_, decl2)) ->
      variable_declaration decl1 decl2
    | (InitExpression expr1, InitExpression expr2) ->
      Some (diff_if_changed expression expr1 expr2)
    | (InitDeclaration _, InitExpression _)
    | (InitExpression _, InitDeclaration _) ->
      None

  and for_in_statement (stmt1: (Loc.t, Loc.t) Ast.Statement.ForIn.t)
                       (stmt2: (Loc.t, Loc.t) Ast.Statement.ForIn.t)
       : node change list option =
    let open Ast.Statement.ForIn in
    let { left = left1; right = right1; body = body1; each = each1 } = stmt1 in
    let { left = left2; right = right2; body = body2; each = each2 } = stmt2 in
    let left = if left1 == left2 then Some [] else for_in_statement_lhs left1 left2 in
    let body = Some (diff_if_changed statement body1 body2) in
    let right = Some (diff_if_changed expression right1 right2) in
    let each = if each1 != each2 then None else Some [] in
    Option.all [left; right; body; each] |> Option.map ~f:List.concat

  and for_in_statement_lhs (left1: (Loc.t, Loc.t) Ast.Statement.ForIn.left)
                            (left2: (Loc.t, Loc.t) Ast.Statement.ForIn.left)
      : node change list option =
    let open Ast.Statement.ForIn in
    match (left1, left2) with
    | (LeftDeclaration(_, decl1), LeftDeclaration(_, decl2)) ->
      variable_declaration decl1 decl2
    | (LeftPattern p1, LeftPattern p2) ->
      Some (pattern p1 p2)
    | (LeftDeclaration _, LeftPattern _)
    | (LeftPattern _, LeftDeclaration _) ->
      None

  and while_statement (stmt1: (Loc.t, Loc.t) Ast.Statement.While.t)
                      (stmt2: (Loc.t, Loc.t) Ast.Statement.While.t)
      : node change list =
    let open Ast.Statement.While in
    let { test = test1; body = body1 } = stmt1 in
    let { test = test2; body = body2 } = stmt2 in
    let test = diff_if_changed expression test1 test2 in
    let body = diff_if_changed statement body1 body2 in
    test @ body

  and for_of_statement (stmt1: (Loc.t, Loc.t) Ast.Statement.ForOf.t)
                       (stmt2: (Loc.t, Loc.t) Ast.Statement.ForOf.t)
      : node change list option =
    let open Ast.Statement.ForOf in
    let { left = left1; right = right1; body = body1; async = async1 } = stmt1 in
    let { left = left2; right = right2; body = body2; async = async2 } = stmt2 in
    let left = if left1 == left2 then Some [] else for_of_statement_lhs left1 left2 in
    let body = Some (diff_if_changed statement body1 body2) in
    let right = Some (diff_if_changed expression right1 right2) in
    let async = if async1 != async2 then None else Some [] in
    Option.all [left; right; body; async] |> Option.map ~f:List.concat

  and for_of_statement_lhs (left1: (Loc.t, Loc.t) Ast.Statement.ForOf.left)
                            (left2: (Loc.t, Loc.t) Ast.Statement.ForOf.left)
      : node change list option =
    let open Ast.Statement.ForOf in
    match (left1, left2) with
    | (LeftDeclaration(_, decl1), LeftDeclaration(_, decl2)) ->
      variable_declaration decl1 decl2
    | (LeftPattern p1, LeftPattern p2) ->
      Some (pattern p1 p2)
    | (LeftDeclaration _, LeftPattern _)
    | (LeftPattern _, LeftDeclaration _) ->
      None

  and do_while_statement (stmt1: (Loc.t, Loc.t) Ast.Statement.DoWhile.t)
                         (stmt2: (Loc.t, Loc.t) Ast.Statement.DoWhile.t)
      : node change list =
    let open Ast.Statement.DoWhile in
    let { body = body1; test = test1 } = stmt1 in
    let { body = body2; test = test2 } = stmt2 in
    let body = diff_if_changed statement body1 body2 in
    let test = diff_if_changed expression test1 test2 in
    List.concat [body; test]

  and return_statement (stmt1: (Loc.t, Loc.t) Ast.Statement.Return.t)
                       (stmt2: (Loc.t, Loc.t) Ast.Statement.Return.t)
      : node change list option =
    let open Ast.Statement.Return in
    let { argument = argument1; } = stmt1 in
    let { argument = argument2; } = stmt2 in
    diff_if_changed_nonopt_fn expression argument1 argument2

  and switch_statement (stmt1: (Loc.t, Loc.t) Ast.Statement.Switch.t)
                       (stmt2: (Loc.t, Loc.t) Ast.Statement.Switch.t)
      : node change list option =
    let open Ast.Statement.Switch in
    let { discriminant = discriminant1; cases = cases1} = stmt1 in
    let { discriminant = discriminant2; cases = cases2} = stmt2 in
    let discriminant = Some (diff_if_changed expression discriminant1 discriminant2) in
    let cases = diff_and_recurse_no_trivial switch_case cases1 cases2 in
    Option.all [discriminant; cases] |> Option.map ~f:List.concat

  and switch_case ((_, s1): (Loc.t, Loc.t) Ast.Statement.Switch.Case.t)
                  ((_, s2): (Loc.t, Loc.t) Ast.Statement.Switch.Case.t)
      : node change list option =
    let open Ast.Statement.Switch.Case in
    let { test = test1; consequent = consequent1} = s1 in
    let { test = test2; consequent = consequent2} = s2 in
    let test = diff_if_changed_nonopt_fn expression test1 test2 in
    let consequent = statement_list consequent1 consequent2 in
    Option.all [test; consequent] |> Option.map ~f:List.concat

  and pattern (p1: (Loc.t, Loc.t) Ast.Pattern.t)
              (p2: (Loc.t, Loc.t) Ast.Pattern.t)
      : node change list =
    let changes = match p1, p2 with
      | (_, Ast.Pattern.Identifier i1), (_, Ast.Pattern.Identifier i2) ->
          pattern_identifier i1 i2
      | (_, Ast.Pattern.Array a1), (_, Ast.Pattern.Array a2) ->
          pattern_array a1 a2
      | (_, Ast.Pattern.Object o1), (_, Ast.Pattern.Object o2) ->
          pattern_object o1 o2
      | (_, Ast.Pattern.Assignment a1), (_, Ast.Pattern.Assignment a2) ->
          Some (pattern_assignment a1 a2)
      | (_, Ast.Pattern.Expression e1), (_, Ast.Pattern.Expression e2) ->
          Some (expression e1 e2)
      | _, _ ->
          None
        in
      let old_loc = Ast_utils.loc_of_pattern p1 in
      Option.value changes ~default:[(old_loc, Replace (Pattern p1, Pattern p2))]

  and pattern_assignment (a1: (Loc.t, Loc.t) Ast.Pattern.Assignment.t)
                         (a2: (Loc.t, Loc.t) Ast.Pattern.Assignment.t)
      : node change list =
    let open Ast.Pattern.Assignment in
    let { left = left1; right = right1 } = a1 in
    let { left = left2; right = right2 } = a2 in
    let left_diffs = diff_if_changed pattern left1 left2 in
    let right_diffs = diff_if_changed expression right1 right2 in
    left_diffs @ right_diffs

  and pattern_object (o1: (Loc.t, Loc.t) Ast.Pattern.Object.t)
                     (o2: (Loc.t, Loc.t) Ast.Pattern.Object.t)
      : node change list option =
    let open Ast.Pattern.Object in
    let { properties = properties1; annot = annot1 } = o1 in
    let { properties = properties2; annot = annot2 } = o2 in
    if annot1 != annot2 then
        None
    else
        diff_and_recurse_no_trivial pattern_object_property properties1 properties2

  and pattern_object_property (p1: (Loc.t, Loc.t) Ast.Pattern.Object.property)
                              (p2: (Loc.t, Loc.t) Ast.Pattern.Object.property)
      : node change list option =
    let open Ast.Pattern.Object in
    match p1, p2 with
    | (Property (_, p3), Property (_, p4)) ->
        let open Ast.Pattern.Object.Property in
        let { key = key1; pattern = pattern1; shorthand = shorthand1; } = p3 in
        let { key = key2; pattern = pattern2; shorthand = shorthand2; } = p4 in
        let keys = diff_if_changed_opt pattern_object_property_key (Some key1) (Some key2) in
        let pats = Some (diff_if_changed pattern pattern1 pattern2) in
        (match shorthand1, shorthand2 with
        | false, false ->
          Option.all [keys; pats] |> Option.map ~f:List.concat
        | _, _ ->
          None)
    | (RestProperty (_, rp1) ,RestProperty (_, rp2)) ->
        let open Ast.Pattern.Object.RestProperty in
        let { argument = argument1 } = rp1 in
        let { argument = argument2 } = rp2 in
        Some (diff_if_changed pattern argument1 argument2)
    | _, _ ->
        None

  and pattern_object_property_key (k1: (Loc.t, Loc.t) Ast.Pattern.Object.Property.key)
                                  (k2: (Loc.t, Loc.t) Ast.Pattern.Object.Property.key)
      : node change list option =
    let open Ast.Pattern.Object.Property in
    match k1, k2 with
    | Literal _, Literal _ ->
        (* TODO: recurse into literals *)
        None
    | Ast.Pattern.Object.Property.Identifier i1, Ast.Pattern.Object.Property.Identifier i2 ->
        identifier i1 i2 |> Option.return
    | Computed e1, Computed e2 ->
        Some (expression e1 e2)
    | _, _ ->
        None

  and pattern_array (a1: (Loc.t, Loc.t) Ast.Pattern.Array.t)
                    (a2: (Loc.t, Loc.t) Ast.Pattern.Array.t)
      : node change list option =
    let open Ast.Pattern.Array in
    let { elements = elements1; annot = annot1 } = a1 in
    let { elements = elements2; annot = annot2 } = a2 in
    if annot1 != annot2 then
        None
    else
        diff_and_recurse_no_trivial pattern_array_element elements1 elements2

  and pattern_array_element (eo1: (Loc.t, Loc.t) Ast.Pattern.Array.element option)
                            (eo2: (Loc.t, Loc.t) Ast.Pattern.Array.element option)
      : node change list option =
    let open Ast.Pattern.Array in
    match eo1, eo2 with
    | Some (Element p1), Some (Element p2) ->
        Some (pattern p1 p2)
    | Some (RestElement re1), Some (RestElement re2) ->
        Some (pattern_array_rest re1 re2)
    | None, None ->
        Some [] (* Both elements elided *)
    | _, _ ->
        None (* one element is elided and another is not *)

  and pattern_array_rest ((_, r1): (Loc.t, Loc.t) Ast.Pattern.Array.RestElement.t)
                         ((_, r2): (Loc.t, Loc.t) Ast.Pattern.Array.RestElement.t)
      : node change list =
    let open Ast.Pattern.Array.RestElement in
    let { argument = argument1 } = r1 in
    let { argument = argument2 } = r2 in
      pattern argument1 argument2

  and pattern_identifier (i1: (Loc.t, Loc.t) Ast.Pattern.Identifier.t)
                         (i2: (Loc.t, Loc.t) Ast.Pattern.Identifier.t)
      : node change list option =
    let open Ast.Pattern.Identifier in
    let { name = name1; annot = annot1; optional = optional1 } = i1 in
    let { name = name2; annot = annot2; optional = optional2 } = i2 in
    if optional1 != optional2 then
      None
    else
      let ids = diff_if_changed identifier name1 name2 |> Option.return in
      let annots = diff_if_changed_opt_arg type_annotation annot1 annot2 in
      Option.(all [ids; annots] >>| List.concat)

  and type_annotation (annot1: (Loc.t, Loc.t) Ast.Type.annotation option)
                      (annot2: (Loc.t, Loc.t) Ast.Type.annotation option)
      : node change list option =
    match annot1, annot2 with
    | None, None -> Some []
    | Some (loc, typ), None -> Some [loc, Delete (TypeAnnotation (loc, typ))]
    | None, Some _ -> None (* Nowhere in the original program to insert the annotation *)
    | Some (loc1, typ1), Some (loc2, typ2) ->
        Some [loc1, Replace (TypeAnnotation (loc1, typ1), TypeAnnotation (loc2, typ2))] in

program' program1 program2
