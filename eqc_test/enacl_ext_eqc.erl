-module(enacl_ext_eqc).

-include_lib("eqc/include/eqc.hrl").
-compile(export_all).

public_keypair() ->
    ?LET(#{ public := PK, secret := SK}, enacl_p_ext:curve25519_keypair(),
         {PK, SK}).

prop_public_key() ->
    ?FORALL({PK, SK}, public_keypair(),
        begin
            equals(PK, enacl_p_ext:curve25519_public_key(SK))
        end).

prop_shared_secret() ->
    ?FORALL([{PK1, SK1}, {PK2, SK2}],
            [public_keypair(), public_keypair()],
            begin
                Alice = enacl_p_ext:curve25519_shared(SK1, PK2),
                Bob = enacl_p_ext:curve25519_shared(SK2, PK1),
                equals(Alice, Bob)
            end).
