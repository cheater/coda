[%%import
"/src/config.mlh"]

open Core_kernel
open Module_version

(*Constants that can be specified for generating the base proof (that are not required for key-generation) in runtime_genesis_ledger.exe and that can be configured at runtime.
The types are defined such that this module doesn't depend on any of the coda libraries (except blake2 and module_version) to avoid dependency cycles.
TODO: move key generation to runtime_genesis_ledger.exe to include scan_state constants, consensus constants (c and  block_window_duration) and ledger depth here*)

let genesis_timestamp_of_string str =
  let default_timezone = Core.Time.Zone.of_utc_offset ~hours:(-8) in
  Core.Time.of_string_gen ~if_no_timezone:(`Use_this_one default_timezone) str

let validate_time time_str =
  match
    Result.try_with (fun () ->
        Option.value_map ~default:(Time.now ()) ~f:genesis_timestamp_of_string
          time_str )
  with
  | Ok time ->
      Ok time
  | Error _ ->
      Error
        "Invalid timestamp. Please specify timestamp in \"%Y-%m-%d \
         %H:%M:%S%z\". For example, \"2019-01-30 12:00:00-0800\" for \
         UTC-08:00 timezone"

(*Protocol constants required for consensus and snarks. Consensus constants is generated using these*)
module Protocol = struct
  module Poly = struct
    [%%versioned
    module Stable = struct
      module V1 = struct
        type ('k, 'delta, 'genesis_state_timestamp) t =
          { k: 'k
          ; delta: 'delta
          ; genesis_state_timestamp: 'genesis_state_timestamp }
        [@@deriving eq, ord, hash, sexp, yojson]
      end
    end]

    type ('k, 'delta, 'genesis_state_timestamp) t =
          ('k, 'delta, 'genesis_state_timestamp) Stable.Latest.t =
      {k: 'k; delta: 'delta; genesis_state_timestamp: 'genesis_state_timestamp}
    [@@deriving eq]
  end

  module Stable = struct
    module V1 = struct
      module T = struct
        type t = (int, int, Time.t) Poly.Stable.V1.t
        [@@deriving bin_io, version {asserted}, eq, ord, hash]
      end

      include T

      let to_yojson (t : t) =
        `Assoc
          [ ("k", `Int t.k)
          ; ("delta", `Int t.delta)
          ; ( "genesis_state_timestamp"
            , `String
                (Time.to_string_abs t.genesis_state_timestamp
                   ~zone:Time.Zone.utc) ) ]

      let of_yojson = function
        | `Assoc
            [ ("k", `Int k)
            ; ("delta", `Int delta)
            ; ("genesis_state_timestamp", `String time_str) ] -> (
          match validate_time time_str with
          | Ok genesis_state_timestamp ->
              Ok {Poly.k; delta; genesis_state_timestamp}
          | Error e ->
              Error (sprintf !"Genesis_constants.Protocol.of_yojson: %s" e) )
        | _ ->
            Error "Genesis_constants.Protocol.of_yojson: unexpected JSON"

      let t_of_sexp _ = failwith "t_of_sexp: not implemented"

      let sexp_of_t (t : t) =
        let module T = struct
          type t = (int, int, string) Poly.Stable.V1.t [@@deriving sexp]
        end in
        let t' : T.t =
          { k= t.k
          ; delta= t.delta
          ; genesis_state_timestamp=
              Time.to_string_abs t.genesis_state_timestamp ~zone:Time.Zone.utc
          }
        in
        T.sexp_of_t t'

      include Registration.Make_latest_version (T)
    end

    module Latest = V1

    module Module_decl = struct
      let name = "protocol_constants"

      type latest = Latest.t
    end

    module Registrar = Registration.Make (Module_decl)
    module Registered_V1 = Registrar.Register (V1)

    (* see lib/module_version/README-version-asserted.md *)
    module For_tests = struct
      let%test "protocol constants serialization v1" =
        let t : V1.t =
          { k= 1
          ; delta= 100
          ; genesis_state_timestamp=
              Time.of_string "2019-10-08 17:51:23.050849Z" }
        in
        (*from the print statement in Serialization.check_serialization*)
        let known_good_hash =
          "\x18\x3E\xF4\x11\xAC\x44\x83\xBF\x0E\x0F\x76\x5B\xF7\xE6\xFA\xE7\xEB\x24\xF6\xF7\xAA\xC8\x37\x71\xF7\xB9\x54\x66\xF6\x38\xB3\xF1"
        in
        Serialization.check_serialization (module V1) t known_good_hash
    end
  end

  type t = Stable.Latest.t [@@deriving eq]
end

type t = {protocol: Protocol.t; txpool_max_size: int}

let hash (t : t) =
  let str =
    ( List.map
        [t.protocol.k; t.protocol.delta; t.txpool_max_size]
        ~f:Int.to_string
    |> String.concat ~sep:"" )
    ^ Core.Time.to_string t.protocol.genesis_state_timestamp
  in
  Blake2.digest_string str |> Blake2.to_hex

[%%inject
"genesis_state_timestamp_string", genesis_state_timestamp]

[%%ifdef
consensus_mechanism]

[%%inject
"k", k]

[%%inject
"delta", delta]

[%%endif]

[%%inject
"pool_max_size", pool_max_size]

let compiled : t =
  { protocol=
      { k
      ; delta
      ; genesis_state_timestamp=
          genesis_timestamp_of_string genesis_state_timestamp_string }
  ; txpool_max_size= pool_max_size }

module Config_file = struct
  type t =
    { k: int option
    ; delta: int option
    ; txpool_max_size: int option
    ; genesis_state_timestamp: string option }
  [@@deriving yojson]

  let of_yojson s =
    Result.(
      of_yojson s
      >>= fun t -> validate_time t.genesis_state_timestamp >>= fun _ -> Ok t)
end

module Daemon_config = struct
  type t = {txpool_max_size: int option; genesis_state_timestamp: string option}
  [@@deriving yojson, eq]

  let of_yojson s =
    Result.(
      of_yojson s
      >>= fun t -> validate_time t.genesis_state_timestamp >>= fun _ -> Ok t)
end

let of_config_file ~(default : t) (t : Config_file.t) : t =
  let opt default x = Option.value ~default x in
  let protocol =
    { Protocol.Poly.k= opt default.protocol.k t.k
    ; delta= opt default.protocol.delta t.delta
    ; genesis_state_timestamp=
        Option.value_map ~default:default.protocol.genesis_state_timestamp
          t.genesis_state_timestamp ~f:genesis_timestamp_of_string }
  in
  {protocol; txpool_max_size= opt default.txpool_max_size t.txpool_max_size}

let to_config_file t : Config_file.t =
  { Config_file.k= Some t.protocol.k
  ; delta= Some t.protocol.delta
  ; txpool_max_size= Some t.txpool_max_size
  ; genesis_state_timestamp=
      Some
        (Core.Time.format t.protocol.genesis_state_timestamp
           "%Y-%m-%d %H:%M:%S%z" ~zone:Core.Time.Zone.utc) }

let of_daemon_config ~(default : t)
    ({txpool_max_size; genesis_state_timestamp} : Daemon_config.t) : t =
  { txpool_max_size=
      Option.value ~default:default.txpool_max_size txpool_max_size
  ; protocol=
      { default.protocol with
        genesis_state_timestamp=
          Option.value_map genesis_state_timestamp
            ~default:default.protocol.genesis_state_timestamp
            ~f:genesis_timestamp_of_string } }

let to_daemon_config (t : t) : Daemon_config.t =
  { txpool_max_size= Some t.txpool_max_size
  ; genesis_state_timestamp=
      Some
        (Core.Time.format t.protocol.genesis_state_timestamp
           "%Y-%m-%d %H:%M:%S%z" ~zone:Core.Time.Zone.utc) }
