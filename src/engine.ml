open State



let next_message_id state =
  state.my_message_id, { state with my_message_id = Int32.succ state.my_message_id }

let header timestamp state =
  let rec acked_message_ids id =
    if state.their_message_id = id then
      []
    else
      id :: acked_message_ids (Int32.succ id)
  in
  let ack_message_ids = acked_message_ids state.their_last_acked_message_id in
  let remote_session = match ack_message_ids with [] -> None | _ -> Some state.their_session_id in
  { Packet.local_session = state.my_session_id ;
    hmac = Cstruct.create_unsafe Packet.hmac_len ;
    packet_id = state.my_packet_id ;
    timestamp ;
    ack_message_ids ;
    remote_session
  }, {
    state with their_last_acked_message_id = state.their_message_id ;
               my_packet_id = Int32.succ state.my_packet_id
  }

let ptime_to_ts_exn now =
  let now = now () in
  match Ptime.(Span.to_int_s (to_span now)) with
  | None -> assert false
  | Some x -> Int32.of_int x

let client config now () =
  let open Rresult.R.Infix in
  hmac_keys config >>| fun (_a, my_hmac, _c, _d) ->
  let state = {
    config ; key = 0 ; state = Client_reset ;
    my_hmac ;
    my_session_id = 0xF00DBEEFL ;
    my_packet_id = 1l ;
    my_message_id = 0l ;
    their_hmac = my_hmac ;
    their_session_id = 0L ;
    their_packet_id = 1l ;
    their_message_id = 0l ;
    their_last_acked_message_id = 0l ;
  } in
  let timestamp = ptime_to_ts_exn now in
  let header, state = header timestamp state in
  let m_id, state = next_message_id state in
  let p =
    let p = `Control (Packet.Hard_reset_client, (header, m_id, Cstruct.empty)) in
    let tbs = Packet.to_be_signed state.key p in
    let hmac = Nocrypto.Hash.SHA1.hmac ~key:my_hmac tbs in
    `Control (Packet.Hard_reset_client, ({ header with hmac }, m_id, Cstruct.empty))
  in
  state, Packet.encode (state.key, p)

let handle state _now buf =
  match Packet.decode buf with
  | Error e ->
    Logs.err (fun m -> m "decoding failed %a@.%a" Packet.pp_error e Cstruct.hexdump_pp buf)
  | Ok data ->
    Logs.info (fun m -> m "state %a, received %a" State.pp state Packet.pp data)
