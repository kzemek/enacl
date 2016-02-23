-module(enacl_eqc).
-include_lib("eqc/include/eqc.hrl").
-compile(export_all).

non_byte_int() ->
    oneof([
        ?LET(N, nat(), -(N+1)),
        ?LET(N, nat(), N+256)
    ]).

g_iolist() ->
    ?SIZED(Sz, g_iolist(Sz)).

g_iolist(0) ->
    fault(
        oneof([
          elements([a,b,c]),
          real(),
          non_byte_int()
        ]),
        return([]));
g_iolist(N) ->
    fault(
        oneof([
          elements([a,b,c]),
          real(),
          non_byte_int()
        ]),
        frequency([
            {1, g_iolist(0)},
            {N, ?LAZY(list(oneof([char(), binary(), g_iolist(N div 4)])))}
        ])).

g_iodata() ->
    fault(
      oneof([elements([a,b,c]), real()]),
      oneof([binary(), g_iolist(), eqc_gen:largebinary(64*1024)])).

v_iolist([]) -> true;
v_iolist([B|Xs]) when is_binary(B) -> v_iolist(Xs);
v_iolist([C|Xs]) when is_integer(C), C >= 0, C < 256 -> v_iolist(Xs);
v_iolist([L|Xs]) when is_list(L) ->
    v_iolist(L) andalso v_iolist(Xs);
v_iolist(_) -> false.

v_iodata(B) when is_binary(B) -> true;
v_iodata(Structure) -> v_iolist(Structure).

%% Generator for binaries of a given size with different properties and fault injection:
g_binary(Sz) ->
    fault(g_binary_bad(Sz), g_binary_good(Sz)).

g_binary_good(Sz) when Sz =< 32 -> binary(Sz);
g_binary_good(Sz) -> eqc_gen:largebinary(Sz).

g_binary_bad(Sz) ->
    frequency([
        {5, ?SUCHTHAT(B, binary(), byte_size(B) /= Sz)},
        {1, elements([a, b])},
        {1, int()},
        {1, g_iodata()}
    ]).

v_binary(Sz, N) when is_binary(N) ->
    byte_size(N) == Sz;
v_binary(_, _) -> false.


%% Typical generators based on the binaries
nonce() -> g_binary(enacl_p:box_nonce_size()).
nonce_valid(N) -> v_binary(enacl_p:box_nonce_size(), N).

%% Generator of natural numbers
g_nat() ->
    fault(g_nat_bad(), nat()).

g_nat_bad() ->
    oneof([
        elements([a,b,c]),
        real(),
        binary(),
        ?LET(X, nat(), -X)
    ]).

is_nat(N) when is_integer(N), N >= 0 -> true;
is_nat(_) -> false.

keypair_good() ->
    #{ public := PK, secret := SK} = enacl_p:box_keypair(),
    {PK, SK}.

keypair_bad() ->
    ?LET(X, elements([pk, sk]),
      begin
        #{ public := PK, secret := SK} = enacl_p:box_keypair(),
        case X of
            pk ->
              PKBytes = enacl_p:box_public_key_bytes(),
              {oneof([return(a), nat(), ?SUCHTHAT(B, binary(), byte_size(B) /= PKBytes)]), SK};
            sk ->
              SKBytes = enacl_p:box_secret_key_bytes(),
              {PK, oneof([return(a), nat(), ?SUCHTHAT(B, binary(), byte_size(B) /= SKBytes)])}
        end
      end).

keypair() ->
    fault(keypair_bad(), keypair_good()).

%% CRYPTO BOX
%% ---------------------------

keypair_valid(PK, SK) when is_binary(PK), is_binary(SK) ->
    PKBytes = enacl_p:box_public_key_bytes(),
    SKBytes = enacl_p:box_secret_key_bytes(),
    byte_size(PK) == PKBytes andalso byte_size(SK) == SKBytes;
keypair_valid(_PK, _SK) -> false.

prop_box_keypair() ->
    ?FORALL(_X, return(dummy),
        ok_box_keypair(enacl_p:box_keypair())).

ok_box_keypair(#{ public := _, secret := _}) -> true;
ok_box_keypair(_) -> false.

box(Msg, Nonce , PK, SK) ->
    try
        enacl_p:box(Msg, Nonce, PK, SK)
    catch
        error:badarg -> badarg
    end.

box_seal(Msg, PK) ->
    try
        enacl_p:box_seal(Msg, PK)
    catch
       error:badarg -> badarg
    end.

box_seal_open(Cph, PK, SK) ->
    try
        enacl_p:box_seal_open(Cph, PK, SK)
    catch
        error:badarg -> badarg
    end.

box_open(CphText, Nonce, PK, SK) ->
    try
        enacl_p:box_open(CphText, Nonce, PK, SK)
    catch
         error:badarg -> badarg
    end.

failure(badarg) -> true;
failure({error, failed_verification}) -> true;
failure(X) -> {failure, X}.

prop_box_correct() ->
    ?FORALL({Msg, Nonce, {PK1, SK1}, {PK2, SK2}},
            {fault_rate(1, 40, g_iodata()),
             fault_rate(1, 40, nonce()),
             fault_rate(1, 40, keypair()),
             fault_rate(1, 40, keypair())},
        begin
            case v_iodata(Msg) andalso nonce_valid(Nonce) andalso keypair_valid(PK1, SK1) andalso keypair_valid(PK2, SK2) of
                true ->
                    Key = enacl_p:box_beforenm(PK2, SK1),
                    Key = enacl_p:box_beforenm(PK1, SK2),
                    CipherText = enacl_p:box(Msg, Nonce, PK2, SK1),
                    CipherText = enacl_p:box_afternm(Msg, Nonce, Key),
                    {ok, DecodedMsg} = enacl_p:box_open(CipherText, Nonce, PK1, SK2),
                    {ok, DecodedMsg} = enacl_p:box_open_afternm(CipherText, Nonce, Key),
                    equals(iolist_to_binary(Msg), DecodedMsg);
                false ->
                    case box(Msg, Nonce, PK2, SK1) of
                        badarg -> true;
                        Res -> failure(box_open(Res, Nonce, PK1, SK2))
                    end
            end
        end).

prop_box_failure_integrity() ->
    ?FORALL({Msg, Nonce, {PK1, SK1}, {PK2, SK2}},
            {fault_rate(1, 40, g_iodata()),
             fault_rate(1, 40, nonce()),
             fault_rate(1, 40, keypair()),
             fault_rate(1, 40, keypair())},
        begin
            case v_iodata(Msg)
                 andalso nonce_valid(Nonce)
                 andalso keypair_valid(PK1, SK1)
                 andalso keypair_valid(PK2, SK2) of
                true ->
                    Key = enacl_p:box_beforenm(PK2, SK1),
                    CipherText = enacl_p:box(Msg, Nonce, PK2, SK1),
                    Err = enacl_p:box_open([<<"x">>, CipherText], Nonce, PK1, SK2),
                    Err = enacl_p:box_open_afternm([<<"x">>, CipherText], Nonce, Key),
                    equals(Err, {error, failed_verification});
                false ->
                    case box(Msg, Nonce, PK2, SK1) of
                      badarg -> true;
                      Res ->
                        failure(box_open(Res, Nonce, PK1, SK2))
                    end
            end
        end).

prop_seal_box_failure_integrity() ->
    ?FORALL({Msg, {PK1, SK1}}, {fault_rate(1,40,g_iodata()), fault_rate(1,40,keypair())},
      begin
         case v_iodata(Msg) andalso keypair_valid(PK1, SK1) of
           true ->
             CT = enacl_p:box_seal(Msg, PK1),
             Err = enacl_p:box_seal_open([<<"x">>, CT], PK1, SK1),
             equals(Err, {error, failed_verification});
           false ->
             case box_seal(Msg, PK1) of
                 badarg -> true;
                 Res ->
                    failure(box_seal_open(Res, PK1, SK1))
            end
        end
    end).

prop_seal_box_correct() ->
    ?FORALL({Msg, {PK1, SK1}},
        {fault_rate(1, 40, g_iodata()),
         fault_rate(1, 40, keypair())},
     begin
         case v_iodata(Msg) andalso keypair_valid(PK1, SK1) of
             true ->
                 SealedCipherText = enacl_p:box_seal(Msg, PK1),
                 {ok, DecodedMsg} = enacl_p:box_seal_open(SealedCipherText, PK1, SK1),
                 equals(iolist_to_binary(Msg), DecodedMsg);
             false ->
                case box_seal(Msg, PK1) of
                    badarg -> true;
                    Res -> failure(box_seal_open(Res, PK1, SK1))
                end
         end
     end).

%% PRECOMPUTATIONS
beforenm_key() ->
    ?LET([{PK1, SK1}, {PK2, SK2}], [fault_rate(1, 40, keypair()), fault_rate(1, 40, keypair())],
        case keypair_valid(PK1, SK1) andalso keypair_valid(PK2, SK2) of
            true ->
                enacl_p:box_beforenm(PK1, SK2);
            false ->
                oneof([
                  elements([a,b,c]),
                  real(),
                  ?SUCHTHAT(X, binary(), byte_size(X) /= enacl_p:box_beforenm_bytes())
                  ])
        end).

v_key(K) when is_binary(K) -> byte_size(K) == enacl_p:box_beforenm_bytes();
v_key(_) -> false.

prop_beforenm_correct() ->
    ?FORALL([{PK1, SK1}, {PK2, SK2}], [fault_rate(1, 40, keypair()), fault_rate(1, 40, keypair())],
        case keypair_valid(PK1, SK1) andalso keypair_valid(PK2, SK2) of
            true ->
                equals(enacl_p:box_beforenm(PK1, SK2), enacl_p:box_beforenm(PK2, SK1));
            false ->
                badargs(fun() ->
                	K = enacl_p:box_beforenm(PK1, SK2),
                	K = enacl_p:box_beforenm(PK2, SK1)
                end)
        end).

prop_afternm_correct() ->
    ?FORALL([Msg, Nonce, Key],
        [fault_rate(1, 40, g_iodata()),
         fault_rate(1, 40, nonce()),
         fault_rate(1, 40, beforenm_key())],
      begin
          case v_iodata(Msg) andalso nonce_valid(Nonce) andalso v_key(Key) of
              true ->
                  CipherText = enacl_p:box_afternm(Msg, Nonce, Key),
                  equals({ok, iolist_to_binary(Msg)}, enacl_p:box_open_afternm(CipherText, Nonce, Key));
              false ->
                  try enacl_p:box_afternm(Msg, Nonce, Key) of
                      CipherText ->
                          try enacl_p:box_open_afternm(CipherText, Nonce, Key) of
                              {ok, _M} -> false;
                              {error, failed_validation} -> false
                          catch
                              error:badarg -> true
                          end
                  catch
                      error:badarg -> true
                  end
          end
      end).

%% SIGNATURES
%% ----------

prop_sign_keypair() ->
    ?FORALL(_D, return(dummy),
      begin
        #{ public := _, secret := _ } = enacl_p:sign_keypair(),
        true
      end).

sign_keypair_bad() ->
  ?LET(X, elements([pk, sk]),
    begin
      KP = enacl_p:sign_keypair(),
      case X of
        pk ->
          Sz = enacl_p:sign_keypair_public_size(),
          ?LET(Wrong, oneof([a, int(), ?SUCHTHAT(B, binary(), byte_size(B) /= Sz)]),
            KP#{ public := Wrong });
        sk ->
          Sz = enacl_p:sign_keypair_secret_size(),
          ?LET(Wrong, oneof([a, int(), ?SUCHTHAT(B, binary(), byte_size(B) /= Sz)]),
            KP#{ secret := Wrong })
      end
    end).

sign_keypair_good() ->
  return(enacl_p:sign_keypair()).

sign_keypair() ->
  fault(sign_keypair_bad(), sign_keypair_good()).

sign_keypair_public_valid(#{ public := Public })
  when is_binary(Public) ->
    byte_size(Public) == enacl_p:sign_keypair_public_size();
sign_keypair_public_valid(_) -> false.

sign_keypair_secret_valid(#{ secret := Secret })
  when is_binary(Secret) ->
    byte_size(Secret) == enacl_p:sign_keypair_secret_size();
sign_keypair_secret_valid(_) -> false.

sign_keypair_valid(KP) ->
  sign_keypair_public_valid(KP) andalso sign_keypair_secret_valid(KP).

prop_sign_detached() ->
    ?FORALL({Msg, KeyPair},
        {fault_rate(1, 40, g_iodata()),
         fault_rate(1, 40, sign_keypair())},
      begin
          case v_iodata(Msg) andalso sign_keypair_secret_valid(KeyPair) of
            true ->
                #{ secret := Secret } = KeyPair,
                enacl_p:sign_detached(Msg, Secret),
                true;
            false ->
                #{ secret := Secret } = KeyPair,
                badargs(fun() -> enacl_p:sign_detached(Msg, Secret) end)
          end
      end).

prop_sign() ->
    ?FORALL({Msg, KeyPair},
          {fault_rate(1, 40, g_iodata()),
           fault_rate(1, 40, sign_keypair())},
      begin
        case v_iodata(Msg) andalso sign_keypair_secret_valid(KeyPair) of
          true ->
            #{ secret := Secret } = KeyPair,
            enacl_p:sign(Msg, Secret),
            true;
          false ->
            #{ secret := Secret } = KeyPair,
            badargs(fun() -> enacl_p:sign(Msg, Secret) end)
        end
      end).

signed_message_good(M) ->
    #{ public := PK, secret := SK} = enacl_p:sign_keypair(),
    SM = enacl_p:sign(M, SK),
    frequency([
        {3, return({{valid, SM}, PK})},
        {1, ?LET(X, elements([sm, pk]),
               case X of
                 sm -> {{invalid, binary(byte_size(SM))}, PK};
                 pk -> {{invalid, SM}, binary(byte_size(PK))}
               end)}]).

signed_message_good_d(M) ->
    #{ public := PK, secret := SK} = enacl_p:sign_keypair(),
    Sig = enacl_p:sign_detached(M, SK),
    frequency([
        {3, return({{valid, Sig}, PK})},
        {1, ?LET(X, elements([sm, pk]),
               case X of
                 sm -> {{invalid, binary(byte_size(Sig))}, PK};
                 pk -> {{invalid, Sig}, binary(byte_size(PK))}
               end)}]).

signed_message_bad() ->
    Sz = enacl_p:sign_keypair_public_size(),
    {binary(), oneof([a, int(), ?SUCHTHAT(B, binary(Sz), byte_size(B) /= Sz)])}.

signed_message_bad_d() ->
    Sz = enacl_p:sign_keypair_public_size(),
    {binary(), oneof([a, int(), ?SUCHTHAT(B, binary(Sz), byte_size(B) /= Sz)])}.

signed_message(M) ->
    fault(signed_message_bad(), signed_message_good(M)).

signed_message_d(M) ->
    fault(signed_message_bad(), signed_message_good(M)).

signed_message_valid({valid, _}, _) -> true;
signed_message_valid({invalid, _}, _) -> true;
signed_message_valid(_, _) -> false.

prop_sign_detached_open() ->
    ?FORALL(Msg, g_iodata(),
      ?FORALL({SignMsg, PK}, signed_message_d(Msg),
          case v_iodata(Msg) andalso signed_message_valid(SignMsg, PK) of
              true ->
                  case SignMsg of
                    {valid, Sig} ->
                        equals({ok, Msg}, enacl_p:sign_verify_detached(Sig, Msg, PK));
                    {invalid, Sig} ->
                        equals({error, failed_verification}, enacl_p:sign_verify_detached(Sig, Msg, PK))
                  end;
              false ->
                  badargs(fun() -> enacl_p:sign_verify_detached(SignMsg, Msg, PK) end)
          end)).

prop_sign_open() ->
    ?FORALL(Msg, g_iodata(),
      ?FORALL({SignMsg, PK}, signed_message(Msg),
          case v_iodata(Msg) andalso signed_message_valid(SignMsg, PK) of
              true ->
                  case SignMsg of
                    {valid, SM} ->
                        equals({ok, iolist_to_binary(Msg)}, enacl_p:sign_open(SM, PK));
                    {invalid, SM} ->
                        equals({error, failed_verification}, enacl_p:sign_open(SM, PK))
                  end;
              false ->
                  badargs(fun() -> enacl_p:sign_open(SignMsg, PK) end)
          end)).

%% CRYPTO SECRET BOX
%% -------------------------------

%% Note: key sizes are the same in a lot of situations, so we can use the same generator
%% for keys in many locations.

key_sz(Sz) ->
  equals(enacl_p:secretbox_key_size(), Sz).

prop_key_sizes() ->
    conjunction([{secret, key_sz(enacl_p:secretbox_key_size())},
                 {stream, key_sz(enacl_p:stream_key_size())},
                 {auth, key_sz(enacl_p:auth_key_size())},
                 {onetimeauth, key_sz(enacl_p:onetime_auth_key_size())}]).

nonce_sz(Sz) ->
  equals(enacl_p:secretbox_nonce_size(), Sz).

prop_nonce_sizes() ->
    conjunction([{secret, nonce_sz(enacl_p:secretbox_nonce_size())},
                 {stream, nonce_sz(enacl_p:stream_nonce_size())}]).

secret_key_good() ->
	Sz = enacl_p:secretbox_key_size(),
	binary(Sz).

secret_key_bad() ->
	oneof([return(a),
	       nat(),
	       ?SUCHTHAT(B, binary(), byte_size(B) /= enacl_p:secretbox_key_size())]).

secret_key() ->
	fault(secret_key_bad(), secret_key_good()).

secret_key_valid(SK) when is_binary(SK) ->
	Sz = enacl_p:secretbox_key_size(),
	byte_size(SK) == Sz;
secret_key_valid(_SK) -> false.

secretbox(Msg, Nonce, Key) ->
  try
    enacl_p:secretbox(Msg, Nonce, Key)
  catch
    error:badarg -> badarg
  end.

secretbox_open(Msg, Nonce, Key) ->
  try
    enacl_p:secretbox_open(Msg, Nonce, Key)
  catch
    error:badarg -> badarg
  end.

prop_secretbox_correct() ->
    ?FORALL({Msg, Nonce, Key},
            {fault_rate(1, 40, g_iodata()),
             fault_rate(1, 40, nonce()),
             fault_rate(1, 40, secret_key())},
      begin
        case v_iodata(Msg) andalso nonce_valid(Nonce) andalso secret_key_valid(Key) of
          true ->
             CipherText = enacl_p:secretbox(Msg, Nonce, Key),
             {ok, DecodedMsg} = enacl_p:secretbox_open(CipherText, Nonce, Key),
             equals(iolist_to_binary(Msg), DecodedMsg);
          false ->
             case secretbox(Msg, Nonce, Key) of
               badarg -> true;
               Res ->
                 failure(secretbox_open(Res, Nonce, Key))
             end
        end
      end).

prop_secretbox_failure_integrity() ->
    ?FORALL({Msg, Nonce, Key}, {g_iodata(), nonce(), secret_key()},
      begin
        CipherText = enacl_p:secretbox(Msg, Nonce, Key),
        Err = enacl_p:secretbox_open([<<"x">>, CipherText], Nonce, Key),
        equals(Err, {error, failed_verification})
      end).

%% CRYPTO STREAM
prop_stream_correct() ->
    ?FORALL({Len, Nonce, Key},
            {int(),
             fault_rate(1, 40, nonce()),
             fault_rate(1, 40, secret_key())},
        case Len >= 0 andalso nonce_valid(Nonce) andalso secret_key_valid(Key) of
          true ->
              CipherStream = enacl_p:stream(Len, Nonce, Key),
              equals(Len, byte_size(CipherStream));
          false ->
              badargs(fun() -> enacl_p:stream(Len, Nonce, Key) end)
        end).

xor_bytes(<<A, As/binary>>, <<B, Bs/binary>>) ->
    [A bxor B | xor_bytes(As, Bs)];
xor_bytes(<<>>, <<>>) -> [].

prop_stream_xor_correct() ->
    ?FORALL({Msg, Nonce, Key},
            {fault_rate(1, 40, g_iodata()),
             fault_rate(1, 40, nonce()),
             fault_rate(1, 40, secret_key())},
        case v_iodata(Msg) andalso nonce_valid(Nonce) andalso secret_key_valid(Key) of
            true ->
                Stream = enacl_p:stream(iolist_size(Msg), Nonce, Key),
                CipherText = enacl_p:stream_xor(Msg, Nonce, Key),
                StreamXor = enacl_p:stream_xor(CipherText, Nonce, Key),
                conjunction([
                    {'xor', equals(iolist_to_binary(Msg), StreamXor)},
                    {stream, equals(iolist_to_binary(xor_bytes(Stream, iolist_to_binary(Msg))), CipherText)}
                ]);
            false ->
                badargs(fun() -> enacl_p:stream_xor(Msg, Nonce, Key) end)
        end).

%% CRYPTO AUTH
prop_auth_correct() ->
    ?FORALL({Msg, Key},
            {fault_rate(1, 40, g_iodata()),
             fault_rate(1, 40, secret_key())},
       case v_iodata(Msg) andalso secret_key_valid(Key) of
         true ->
           Authenticator = enacl_p:auth(Msg, Key),
           equals(Authenticator, enacl_p:auth(Msg, Key));
         false ->
           badargs(fun() -> enacl_p:auth(Msg, Key) end)
       end).

authenticator_bad() ->
    oneof([a, int(), ?SUCHTHAT(X, binary(), byte_size(X) /= enacl_p:auth_size())]).

authenticator_good(Msg, Key) when is_binary(Key) ->
    Sz = enacl_p:secretbox_key_size(),
    case v_iodata(Msg) andalso byte_size(Key) == Sz of
      true ->
        frequency([{1, ?LAZY({invalid, binary(enacl_p:auth_size())})},
                   {3, return({valid, enacl_p:auth(Msg, Key)})}]);
      false ->
        binary(enacl_p:auth_size())
    end;
authenticator_good(_Msg, _Key) ->
    binary(enacl_p:auth_size()).

authenticator(Msg, Key) ->
  fault(authenticator_bad(), authenticator_good(Msg, Key)).

authenticator_valid({valid, _}) -> true;
authenticator_valid({invalid, _}) -> true;
authenticator_valid(_) -> false.

prop_auth_verify_correct() ->
    ?FORALL({Msg, Key},
            {fault_rate(1, 40, g_iodata()),
             fault_rate(1, 40, secret_key())},
      ?FORALL(Authenticator, authenticator(Msg, Key),
        case v_iodata(Msg) andalso secret_key_valid(Key) andalso authenticator_valid(Authenticator) of
          true ->
            case Authenticator of
              {valid, A} ->
                equals(true, enacl_p:auth_verify(A, Msg, Key));
              {invalid, A} ->
                equals(false, enacl_p:auth_verify(A, Msg, Key))
            end;
          false ->
            badargs(fun() -> enacl_p:auth_verify(Authenticator, Msg, Key) end)
        end)).

%% CRYPTO ONETIME AUTH
prop_onetimeauth_correct() ->
    ?FORALL({Msg, Key},
            {fault_rate(1, 40, g_iodata()),
             fault_rate(1, 40, secret_key())},
       case v_iodata(Msg) andalso secret_key_valid(Key) of
         true ->
           Authenticator = enacl_p:onetime_auth(Msg, Key),
           equals(Authenticator, enacl_p:onetime_auth(Msg, Key));
         false ->
           badargs(fun() -> enacl_p:onetime_auth(Msg, Key) end)
       end).

ot_authenticator_bad() ->
    oneof([a, int(), ?SUCHTHAT(X, binary(), byte_size(X) /= enacl_p:onetime_auth_size())]).

ot_authenticator_good(Msg, Key) when is_binary(Key) ->
    Sz = enacl_p:secretbox_key_size(),
    case v_iodata(Msg) andalso byte_size(Key) == Sz of
      true ->
        frequency([{1, ?LAZY({invalid, binary(enacl_p:onetime_auth_size())})},
                   {3, return({valid, enacl_p:onetime_auth(Msg, Key)})}]);
      false ->
        binary(enacl_p:onetime_auth_size())
    end;
ot_authenticator_good(_Msg, _Key) ->
    binary(enacl_p:auth_size()).

ot_authenticator(Msg, Key) ->
  fault(ot_authenticator_bad(), ot_authenticator_good(Msg, Key)).

ot_authenticator_valid({valid, _}) -> true;
ot_authenticator_valid({invalid, _}) -> true;
ot_authenticator_valid(_) -> false.

prop_onetime_auth_verify_correct() ->
    ?FORALL({Msg, Key},
            {fault_rate(1, 40, g_iodata()),
             fault_rate(1, 40, secret_key())},
      ?FORALL(Authenticator, ot_authenticator(Msg, Key),
        case v_iodata(Msg) andalso secret_key_valid(Key) andalso ot_authenticator_valid(Authenticator) of
          true ->
            case Authenticator of
              {valid, A} ->
                equals(true, enacl_p:onetime_auth_verify(A, Msg, Key));
              {invalid, A} ->
                equals(false, enacl_p:onetime_auth_verify(A, Msg, Key))
            end;
          false ->
            badargs(fun() -> enacl_p:onetime_auth_verify(Authenticator, Msg, Key) end)
        end)).

%% HASHING
%% ---------------------------
diff_pair() ->
    ?SUCHTHAT({X, Y}, {g_iodata(), g_iodata()},
        iolist_to_binary(X) /= iolist_to_binary(Y)).

prop_crypto_hash_eq() ->
    ?FORALL(X, g_iodata(),
        case v_iodata(X) of
          true -> equals(enacl_p:hash(X), enacl_p:hash(X));
          false ->
            try
              enacl_p:hash(X),
              false
            catch
              error:badarg -> true
            end
        end
    ).

prop_crypto_hash_neq() ->
    ?FORALL({X, Y}, diff_pair(),
        enacl_p:hash(X) /= enacl_p:hash(Y)
    ).

%% STRING COMPARISON
%% -------------------------

verify_pair_bad(Sz) ->
  ?LET(X, elements([fst, snd]),
    case X of
      fst ->
        {?SUCHTHAT(B, binary(), byte_size(B) /= Sz), binary(Sz)};
      snd ->
        {binary(Sz), ?SUCHTHAT(B, binary(), byte_size(B) /= Sz)}
    end).

verify_pair_good(Sz) ->
  oneof([
    ?LET(Bin, binary(Sz), {Bin, Bin}),
    ?SUCHTHAT({X, Y}, {binary(Sz), binary(Sz)}, X /= Y)]).

verify_pair(Sz) ->
  fault(verify_pair_bad(Sz), verify_pair_good(Sz)).

verify_pair_valid(Sz, X, Y) ->
    byte_size(X) == Sz andalso byte_size(Y) == Sz.

prop_verify_16() ->
    ?FORALL({X, Y}, verify_pair(16),
      case verify_pair_valid(16, X, Y) of
          true ->
              equals(X == Y, enacl_p:verify_16(X, Y));
          false ->
              try
                 enacl_p:verify_16(X, Y),
                 false
              catch
                  error:badarg -> true
              end
      end).

prop_verify_32() ->
    ?FORALL({X, Y}, verify_pair(32),
      case verify_pair_valid(32, X, Y) of
          true ->
              equals(X == Y, enacl_p:verify_32(X, Y));
          false ->
              try
                 enacl_p:verify_32(X, Y),
                 false
              catch
                  error:badarg -> true
              end
      end).

%% RANDOMBYTES
prop_randombytes() ->
    ?FORALL(X, g_nat(),
        case is_nat(X) of
            true ->
                is_binary(enacl_p:randombytes(X));
            false ->
                try
                    enacl_p:randombytes(X),
                    false
                catch
                    error:badarg ->
                       true
                end
       end).

%% SCRAMBLING
prop_scramble_block() ->
    ?FORALL({Block, Key}, {binary(16), eqc_gen:largebinary(32)},
        is_binary(enacl_p_ext:scramble_block_16(Block, Key))).

%% HELPERS
badargs(Thunk) ->
  try
    Thunk(),
    false
  catch
    error:badarg -> true
  end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Joel Test Blobs

test_basic_signing() ->
  #{ public := PK0, secret := SK0 } = enacl_p:sign_keypair(),
  #{ public := PK1, secret := SK1 } = enacl_p:sign_keypair(),
  MSG0 = <<"This is super s3Kr3t, srsly!">>,
  [
    %% (+) Sign and open using valid keypair
    case enacl_p:sign_open(enacl_p:sign(MSG0, SK0), PK0) of
        {ok,MSG1} -> MSG0==MSG1;
        _         -> false
    end
  , %% (-) Sign and open using invalid keypair
    case enacl_p:sign_open(enacl_p:sign(MSG0, SK0), PK1) of
        {error,failed_verification} -> true;
        _                           -> false
    end
  , %% (+) Detached mode sig and verify
    { enacl_p:sign_verify_detached(enacl_p:sign_detached(MSG0, SK0), MSG0, PK0)
    , enacl_p:sign_verify_detached(enacl_p:sign_detached(MSG0, SK1), MSG0, PK1)
    }
  , %% (-) Incorrect sigs/PKs/messages given during verify
    { false == enacl_p:sign_verify_detached(enacl_p:sign_detached(MSG0, SK0), MSG0, PK1)
    , false == enacl_p:sign_verify_detached(enacl_p:sign_detached(MSG0, SK1), MSG0, PK0)
    , false == enacl_p:sign_verify_detached(enacl_p:sign_detached(MSG0, SK0), <<"bzzt">>, PK0)
    }
  ].
