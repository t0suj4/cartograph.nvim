// GENERATED — do not edit. pow() as glibc runs it: Arm optimized-routines pow, TRANSLITERATED from C by
// cartograph.cjs in exact mode (CART-1211):
//   source   ~/work/llvm-toolchain-19/libc/AOR_v20.02/math (pow.c, pow_log_data.c, exp_data.c, math_err.c), preprocessed
//            gcc -E -P -mfma -D__attribute__(x)= -I<dir> -I<dir>/include — the FMA build glibc selects on an FMA CPU
//            + the multiply-adds gcc -O2 -mfma FUSES (-ffp-contract=fast), read from its widening_mul dump
//   decided by  gcc (Ubuntu 13.3.0-6ubuntu2~24.04.1) 13.3.0 (the contraction sites are its decisions)
//   matched to  ldd (Ubuntu GLIBC 2.39-0ubuntu8.9) 2.39 — its pow on an FMA CPU (the FMA ifunc path): 5,998,564 of 5,998,564 inputs
//   command  nvim --headless -u NONE -l tools/cjs.lua libmpow <AOR math dir> lua/cartograph/luajs/libmpow.js
// The C source: Copyright (c) 2018, Arm Limited. SPDX-License-Identifier: MIT (as its files state).
'use strict';
// C truthiness: nonzero and non-NULL (offset 0 is never a valid pointer)
const $T = x => x !== 0 && x !== null && x !== undefined;
const $crefuse = what => { throw new Error("[cjs] no faithful form: " + what); };
let H = null; // the byte heap, installed by the caller (setheap)
// the heap image: every static array the code reads, at its fixed offset (offset 0 reserved)
const IMAGE = [

];
const IMAGE_END = 1;
function image() { const h = new Uint8Array(IMAGE_END); for (const [at, vals] of IMAGE) h.set(vals, at); return h; }
const { $fma, $asu64, $asd } = require('./$fpu.js');
const __exp_data = { invln2N: (1.4426950408889634 * ((1 << 7))), shift: 6755399441055744, negln2hiN: -0.0054152123481117087, negln2loN: -1.2864023111638346e-14, poly: [0.49999999999996786, 0.16666666666665886, 0.041666680841067401, 0.0083333358530595491], exp2_shift: (6755399441055744 / ((1 << 7))), exp2_poly: [0.69314718055994529, 0.24022650695909065, 0.0555041086686087, 0.0096181319757210545, 0.0013332074570119598], tab: [BigInt.asUintN(64, BigInt(0x0)), BigInt.asUintN(64, 0x3ff0000000000000n), BigInt.asUintN(64, 0x3c9b3b4f1a88bf6en), BigInt.asUintN(64, 0x3feff63da9fb3335n), 0xbc7160139cd8dc5dn, BigInt.asUintN(64, 0x3fefec9a3e778061n), 0xbc905e7a108766d1n, BigInt.asUintN(64, 0x3fefe315e86e7f85n), BigInt.asUintN(64, 0x3c8cd2523567f613n), BigInt.asUintN(64, 0x3fefd9b0d3158574n), 0xbc8bce8023f98efan, BigInt.asUintN(64, 0x3fefd06b29ddf6den), BigInt.asUintN(64, 0x3c60f74e61e6c861n), BigInt.asUintN(64, 0x3fefc74518759bc8n), BigInt.asUintN(64, 0x3c90a3e45b33d399n), BigInt.asUintN(64, 0x3fefbe3ecac6f383n), BigInt.asUintN(64, 0x3c979aa65d837b6dn), BigInt.asUintN(64, 0x3fefb5586cf9890fn), BigInt.asUintN(64, 0x3c8eb51a92fdeffcn), BigInt.asUintN(64, 0x3fefac922b7247f7n), BigInt.asUintN(64, 0x3c3ebe3d702f9cd1n), BigInt.asUintN(64, 0x3fefa3ec32d3d1a2n), 0xbc6a033489906e0bn, BigInt.asUintN(64, 0x3fef9b66affed31bn), 0xbc9556522a2fbd0en, BigInt.asUintN(64, 0x3fef9301d0125b51n), 0xbc5080ef8c4eea55n, BigInt.asUintN(64, 0x3fef8abdc06c31ccn), 0xbc91c923b9d5f416n, BigInt.asUintN(64, 0x3fef829aaea92de0n), BigInt.asUintN(64, 0x3c80d3e3e95c55afn), BigInt.asUintN(64, 0x3fef7a98c8a58e51n), 0xbc801b15eaa59348n, BigInt.asUintN(64, 0x3fef72b83c7d517bn), 0xbc8f1ff055de323dn, BigInt.asUintN(64, 0x3fef6af9388c8dean), BigInt.asUintN(64, 0x3c8b898c3f1353bfn), BigInt.asUintN(64, 0x3fef635beb6fcb75n), 0xbc96d99c7611eb26n, BigInt.asUintN(64, 0x3fef5be084045cd4n), BigInt.asUintN(64, 0x3c9aecf73e3a2f60n), BigInt.asUintN(64, 0x3fef54873168b9aan), 0xbc8fe782cb86389dn, BigInt.asUintN(64, 0x3fef4d5022fcd91dn), BigInt.asUintN(64, 0x3c8a6f4144a6c38dn), BigInt.asUintN(64, 0x3fef463b88628cd6n), BigInt.asUintN(64, 0x3c807a05b0e4047dn), BigInt.asUintN(64, 0x3fef3f49917ddc96n), BigInt.asUintN(64, 0x3c968efde3a8a894n), BigInt.asUintN(64, 0x3fef387a6e756238n), BigInt.asUintN(64, 0x3c875e18f274487dn), BigInt.asUintN(64, 0x3fef31ce4fb2a63fn), BigInt.asUintN(64, 0x3c80472b981fe7f2n), BigInt.asUintN(64, 0x3fef2b4565e27cddn), 0xbc96b87b3f71085en, BigInt.asUintN(64, 0x3fef24dfe1f56381n), BigInt.asUintN(64, 0x3c82f7e16d09ab31n), BigInt.asUintN(64, 0x3fef1e9df51fdee1n), 0xbc3d219b1a6fbffan, BigInt.asUintN(64, 0x3fef187fd0dad990n), BigInt.asUintN(64, 0x3c8b3782720c0ab4n), BigInt.asUintN(64, 0x3fef1285a6e4030bn), BigInt.asUintN(64, 0x3c6e149289cecb8fn), BigInt.asUintN(64, 0x3fef0cafa93e2f56n), BigInt.asUintN(64, 0x3c834d754db0abb6n), BigInt.asUintN(64, 0x3fef06fe0a31b715n), BigInt.asUintN(64, 0x3c864201e2ac744cn), BigInt.asUintN(64, 0x3fef0170fc4cd831n), BigInt.asUintN(64, 0x3c8fdd395dd3f84an), BigInt.asUintN(64, 0x3feefc08b26416ffn), 0xbc86a3803b8e5b04n, BigInt.asUintN(64, 0x3feef6c55f929ff1n), 0xbc924aedcc4b5068n, BigInt.asUintN(64, 0x3feef1a7373aa9cbn), 0xbc9907f81b512d8en, BigInt.asUintN(64, 0x3feeecae6d05d866n), 0xbc71d1e83e9436d2n, BigInt.asUintN(64, 0x3feee7db34e59ff7n), 0xbc991919b3ce1b15n, BigInt.asUintN(64, 0x3feee32dc313a8e5n), BigInt.asUintN(64, 0x3c859f48a72a4c6dn), BigInt.asUintN(64, 0x3feedea64c123422n), 0xbc9312607a28698an, BigInt.asUintN(64, 0x3feeda4504ac801cn), 0xbc58a78f4817895bn, BigInt.asUintN(64, 0x3feed60a21f72e2an), 0xbc7c2c9b67499a1bn, BigInt.asUintN(64, 0x3feed1f5d950a897n), BigInt.asUintN(64, 0x3c4363ed60c2ac11n), BigInt.asUintN(64, 0x3feece086061892dn), BigInt.asUintN(64, 0x3c9666093b0664efn), BigInt.asUintN(64, 0x3feeca41ed1d0057n), BigInt.asUintN(64, 0x3c6ecce1daa10379n), BigInt.asUintN(64, 0x3feec6a2b5c13cd0n), BigInt.asUintN(64, 0x3c93ff8e3f0f1230n), BigInt.asUintN(64, 0x3feec32af0d7d3den), BigInt.asUintN(64, 0x3c7690cebb7aafb0n), BigInt.asUintN(64, 0x3feebfdad5362a27n), BigInt.asUintN(64, 0x3c931dbdeb54e077n), BigInt.asUintN(64, 0x3feebcb299fddd0dn), 0xbc8f94340071a38en, BigInt.asUintN(64, 0x3feeb9b2769d2ca7n), 0xbc87deccdc93a349n, BigInt.asUintN(64, 0x3feeb6daa2cf6642n), 0xbc78dec6bd0f385fn, BigInt.asUintN(64, 0x3feeb42b569d4f82n), 0xbc861246ec7b5cf6n, BigInt.asUintN(64, 0x3feeb1a4ca5d920fn), BigInt.asUintN(64, 0x3c93350518fdd78en), BigInt.asUintN(64, 0x3feeaf4736b527dan), BigInt.asUintN(64, 0x3c7b98b72f8a9b05n), BigInt.asUintN(64, 0x3feead12d497c7fdn), BigInt.asUintN(64, 0x3c9063e1e21c5409n), BigInt.asUintN(64, 0x3feeab07dd485429n), BigInt.asUintN(64, 0x3c34c7855019c6ean), BigInt.asUintN(64, 0x3feea9268a5946b7n), BigInt.asUintN(64, 0x3c9432e62b64c035n), BigInt.asUintN(64, 0x3feea76f15ad2148n), 0xbc8ce44a6199769fn, BigInt.asUintN(64, 0x3feea5e1b976dc09n), 0xbc8c33c53bef4da8n, BigInt.asUintN(64, 0x3feea47eb03a5585n), 0xbc845378892be9aen, BigInt.asUintN(64, 0x3feea34634ccc320n), 0xbc93cedd78565858n, BigInt.asUintN(64, 0x3feea23882552225n), BigInt.asUintN(64, 0x3c5710aa807e1964n), BigInt.asUintN(64, 0x3feea155d44ca973n), 0xbc93b3efbf5e2228n, BigInt.asUintN(64, 0x3feea09e667f3bcdn), 0xbc6a12ad8734b982n, BigInt.asUintN(64, 0x3feea012750bdabfn), 0xbc6367efb86da9een, BigInt.asUintN(64, 0x3fee9fb23c651a2fn), 0xbc80dc3d54e08851n, BigInt.asUintN(64, 0x3fee9f7df9519484n), 0xbc781f647e5a3ecfn, BigInt.asUintN(64, 0x3fee9f75e8ec5f74n), 0xbc86ee4ac08b7db0n, BigInt.asUintN(64, 0x3fee9f9a48a58174n), 0xbc8619321e55e68an, BigInt.asUintN(64, 0x3fee9feb564267c9n), BigInt.asUintN(64, 0x3c909ccb5e09d4d3n), BigInt.asUintN(64, 0x3feea0694fde5d3fn), 0xbc7b32dcb94da51dn, BigInt.asUintN(64, 0x3feea11473eb0187n), BigInt.asUintN(64, 0x3c94ecfd5467c06bn), BigInt.asUintN(64, 0x3feea1ed0130c132n), BigInt.asUintN(64, 0x3c65ebe1abd66c55n), BigInt.asUintN(64, 0x3feea2f336cf4e62n), 0xbc88a1c52fb3cf42n, BigInt.asUintN(64, 0x3feea427543e1a12n), 0xbc9369b6f13b3734n, BigInt.asUintN(64, 0x3feea589994cce13n), 0xbc805e843a19ff1en, BigInt.asUintN(64, 0x3feea71a4623c7adn), 0xbc94d450d872576en, BigInt.asUintN(64, 0x3feea8d99b4492edn), BigInt.asUintN(64, 0x3c90ad675b0e8a00n), BigInt.asUintN(64, 0x3feeaac7d98a6699n), BigInt.asUintN(64, 0x3c8db72fc1f0eab4n), BigInt.asUintN(64, 0x3feeace5422aa0dbn), 0xbc65b6609cc5e7ffn, BigInt.asUintN(64, 0x3feeaf3216b5448cn), BigInt.asUintN(64, 0x3c7bf68359f35f44n), BigInt.asUintN(64, 0x3feeb1ae99157736n), 0xbc93091fa71e3d83n, BigInt.asUintN(64, 0x3feeb45b0b91ffc6n), 0xbc5da9b88b6c1e29n, BigInt.asUintN(64, 0x3feeb737b0cdc5e5n), 0xbc6c23f97c90b959n, BigInt.asUintN(64, 0x3feeba44cbc8520fn), 0xbc92434322f4f9aan, BigInt.asUintN(64, 0x3feebd829fde4e50n), 0xbc85ca6cd7668e4bn, BigInt.asUintN(64, 0x3feec0f170ca07ban), BigInt.asUintN(64, 0x3c71affc2b91ce27n), BigInt.asUintN(64, 0x3feec49182a3f090n), BigInt.asUintN(64, 0x3c6dd235e10a73bbn), BigInt.asUintN(64, 0x3feec86319e32323n), 0xbc87c50422622263n, BigInt.asUintN(64, 0x3feecc667b5de565n), BigInt.asUintN(64, 0x3c8b1c86e3e231d5n), BigInt.asUintN(64, 0x3feed09bec4a2d33n), 0xbc91bbd1d3bcbb15n, BigInt.asUintN(64, 0x3feed503b23e255dn), BigInt.asUintN(64, 0x3c90cc319cee31d2n), BigInt.asUintN(64, 0x3feed99e1330b358n), BigInt.asUintN(64, 0x3c8469846e735ab3n), BigInt.asUintN(64, 0x3feede6b5579fdbfn), 0xbc82dfcd978e9db4n, BigInt.asUintN(64, 0x3feee36bbfd3f37an), BigInt.asUintN(64, 0x3c8c1a7792cb3387n), BigInt.asUintN(64, 0x3feee89f995ad3adn), 0xbc907b8f4ad1d9fan, BigInt.asUintN(64, 0x3feeee07298db666n), 0xbc55c3d956dcaeban, BigInt.asUintN(64, 0x3feef3a2b84f15fbn), 0xbc90a40e3da6f640n, BigInt.asUintN(64, 0x3feef9728de5593an), 0xbc68d6f438ad9334n, BigInt.asUintN(64, 0x3feeff76f2fb5e47n), 0xbc91eee26b588a35n, BigInt.asUintN(64, 0x3fef05b030a1064an), BigInt.asUintN(64, 0x3c74ffd70a5fddcdn), BigInt.asUintN(64, 0x3fef0c1e904bc1d2n), 0xbc91bdfbfa9298acn, BigInt.asUintN(64, 0x3fef12c25bd71e09n), BigInt.asUintN(64, 0x3c736eae30af0cb3n), BigInt.asUintN(64, 0x3fef199bdd85529cn), BigInt.asUintN(64, 0x3c8ee3325c9ffd94n), BigInt.asUintN(64, 0x3fef20ab5fffd07an), BigInt.asUintN(64, 0x3c84e08fd10959acn), BigInt.asUintN(64, 0x3fef27f12e57d14bn), BigInt.asUintN(64, 0x3c63cdaf384e1a67n), BigInt.asUintN(64, 0x3fef2f6d9406e7b5n), BigInt.asUintN(64, 0x3c676b2c6c921968n), BigInt.asUintN(64, 0x3fef3720dcef9069n), 0xbc808a1883ccb5d2n, BigInt.asUintN(64, 0x3fef3f0b555dc3fan), 0xbc8fad5d3ffffa6fn, BigInt.asUintN(64, 0x3fef472d4a07897cn), 0xbc900dae3875a949n, BigInt.asUintN(64, 0x3fef4f87080d89f2n), BigInt.asUintN(64, 0x3c74a385a63d07a7n), BigInt.asUintN(64, 0x3fef5818dcfba487n), 0xbc82919e2040220fn, BigInt.asUintN(64, 0x3fef60e316c98398n), BigInt.asUintN(64, 0x3c8e5a50d5c192acn), BigInt.asUintN(64, 0x3fef69e603db3285n), BigInt.asUintN(64, 0x3c843a59ac016b4bn), BigInt.asUintN(64, 0x3fef7321f301b460n), 0xbc82d52107b43e1fn, BigInt.asUintN(64, 0x3fef7c97337b9b5fn), 0xbc892ab93b470dc9n, BigInt.asUintN(64, 0x3fef864614f5a129n), BigInt.asUintN(64, 0x3c74b604603a88d3n), BigInt.asUintN(64, 0x3fef902ee78b3ff6n), BigInt.asUintN(64, 0x3c83c5ec519d7271n), BigInt.asUintN(64, 0x3fef9a51fbc74c83n), 0xbc8ff7128fd391f0n, BigInt.asUintN(64, 0x3fefa4afa2a490dan), 0xbc8dae98e223747dn, BigInt.asUintN(64, 0x3fefaf482d8e67f1n), BigInt.asUintN(64, 0x3c8ec3bc41aa2008n), BigInt.asUintN(64, 0x3fefba1bee615a27n), BigInt.asUintN(64, 0x3c842b94c3a9eb32n), BigInt.asUintN(64, 0x3fefc52b376bba97n), BigInt.asUintN(64, 0x3c8a64a931d185een), BigInt.asUintN(64, 0x3fefd0765b6e4540n), 0xbc8e37bae43be3edn, BigInt.asUintN(64, 0x3fefdbfdad9cbe14n), BigInt.asUintN(64, 0x3c77893b4d91cd9dn), BigInt.asUintN(64, 0x3fefe7c1819e90d8n), BigInt.asUintN(64, 0x3c5305c14160cc89n), BigInt.asUintN(64, 0x3feff3c22b8f71f1n)] };
const __pow_log_data = { ln2hi: 0.69314718055989033, ln2lo: 5.4979230187083712e-14, poly: [-0.5, (0.33333333333333393 * (-2)), (-0.25000000000000033 * (-2)), (0.19999999988309941 * 4), (-0.16666666658719348 * 4), (0.14286370355743763 * (-8)), (-0.12500519079594427 * (-8))], tab: [{ invc: 1.4140625, pad: 0, logc: -0.34646676734621451, logctail: 5.9294073458896252e-15 }, { invc: 1.40625, pad: 0, logc: -0.34092658697056777, logctail: -2.544157440035963e-14 }, { invc: 1.3984375, pad: 0, logc: -0.33535554192110339, logctail: -3.4435259407750449e-14 }, { invc: 1.390625, pad: 0, logc: -0.32975328637246548, logctail: -2.500123826022799e-15 }, { invc: 1.3828125, pad: 0, logc: -0.32411946865420305, logctail: -8.9293371338506168e-15 }, { invc: 1.375, pad: 0, logc: -0.31845373111855224, logctail: 1.7625431312172662e-14 }, { invc: 1.3671875, pad: 0, logc: -0.31275571000389846, logctail: 1.5688303180062087e-15 }, { invc: 1.359375, pad: 0, logc: -0.30702503529494152, logctail: 2.9655274673691784e-14 }, { invc: 1.3515625, pad: 0, logc: -0.3012613305781997, logctail: 3.7923164802093147e-14 }, { invc: 1.34375, pad: 0, logc: -0.29546421289387581, logctail: 3.9934163843878439e-14 }, { invc: 1.3359375, pad: 0, logc: -0.28963329258306203, logctail: 1.9352855826489123e-14 }, { invc: 1.3359375, pad: 0, logc: -0.28963329258306203, logctail: 1.9352855826489123e-14 }, { invc: 1.328125, pad: 0, logc: -0.28376817313062475, logctail: -1.9852665484979036e-14 }, { invc: 1.3203125, pad: 0, logc: -0.27786845100342816, logctail: -2.814323765595281e-14 }, { invc: 1.3125, pad: 0, logc: -0.2719337154836694, logctail: 2.7643769993528702e-14 }, { invc: 1.3046875, pad: 0, logc: -0.26596354849709769, logctail: -4.0250924022938059e-14 }, { invc: 1.296875, pad: 0, logc: -0.25995752443691345, logctail: -1.2621729398885316e-14 }, { invc: 1.2890625, pad: 0, logc: -0.25391520998095984, logctail: -3.6001767326373346e-15 }, { invc: 1.2890625, pad: 0, logc: -0.25391520998095984, logctail: -3.6001767326373346e-15 }, { invc: 1.28125, pad: 0, logc: -0.24783616390459429, logctail: 1.3029797173308663e-14 }, { invc: 1.2734375, pad: 0, logc: -0.2417199368871934, logctail: 4.8230289429940886e-14 }, { invc: 1.265625, pad: 0, logc: -0.23556607131274632, logctail: -2.0592242769647135e-14 }, { invc: 1.2578125, pad: 0, logc: -0.22937410106487732, logctail: 3.1492650651914838e-14 }, { invc: 1.25, pad: 0, logc: -0.22314355131425145, logctail: 4.1697965845271953e-14 }, { invc: 1.25, pad: 0, logc: -0.22314355131425145, logctail: 4.1697965845271953e-14 }, { invc: 1.2421875, pad: 0, logc: -0.21687393830063684, logctail: 2.2477465222466186e-14 }, { invc: 1.234375, pad: 0, logc: -0.21056476910735, logctail: 3.6507188831790577e-16 }, { invc: 1.2265625, pad: 0, logc: -0.20421554142865261, logctail: -3.8277672602054141e-14 }, { invc: 1.2265625, pad: 0, logc: -0.20421554142865261, logctail: -3.8277672602054141e-14 }, { invc: 1.21875, pad: 0, logc: -0.19782574332987224, logctail: -4.7641388950792196e-14 }, { invc: 1.2109375, pad: 0, logc: -0.19139485299967873, logctail: 4.9278276214647115e-14 }, { invc: 1.203125, pad: 0, logc: -0.18492233849406148, logctail: 4.9485167661250996e-14 }, { invc: 1.203125, pad: 0, logc: -0.18492233849406148, logctail: 4.9485167661250996e-14 }, { invc: 1.1953125, pad: 0, logc: -0.17840765747280329, logctail: -1.5003333854266542e-14 }, { invc: 1.1875, pad: 0, logc: -0.17185025692663203, logctail: -2.7194441649495324e-14 }, { invc: 1.1875, pad: 0, logc: -0.17185025692663203, logctail: -2.7194441649495324e-14 }, { invc: 1.1796875, pad: 0, logc: -0.1652495728952772, logctail: -2.9965926729256903e-14 }, { invc: 1.171875, pad: 0, logc: -0.15860503017665906, logctail: 2.0472357800461955e-14 }, { invc: 1.171875, pad: 0, logc: -0.15860503017665906, logctail: 2.0472357800461955e-14 }, { invc: 1.1640625, pad: 0, logc: -0.15191604202584585, logctail: 3.8792967230636458e-15 }, { invc: 1.15625, pad: 0, logc: -0.14518200984446139, logctail: -3.6506824353335045e-14 }, { invc: 1.1484375, pad: 0, logc: -0.13840232285906495, logctail: -5.4183331379008994e-14 }, { invc: 1.1484375, pad: 0, logc: -0.13840232285906495, logctail: -5.4183331379008994e-14 }, { invc: 1.140625, pad: 0, logc: -0.131576357788731, logctail: 1.1729485484531301e-14 }, { invc: 1.140625, pad: 0, logc: -0.131576357788731, logctail: 1.1729485484531301e-14 }, { invc: 1.1328125, pad: 0, logc: -0.12470347850091912, logctail: -3.8117630847102661e-14 }, { invc: 1.125, pad: 0, logc: -0.11778303565643, logctail: 4.6547297475984447e-14 }, { invc: 1.125, pad: 0, logc: -0.11778303565643, logctail: 4.6547297475984447e-14 }, { invc: 1.1171875, pad: 0, logc: -0.11081436634026431, logctail: -2.5799991283069902e-14 }, { invc: 1.109375, pad: 0, logc: -0.10379679368168127, logctail: 3.7700471749674615e-14 }, { invc: 1.109375, pad: 0, logc: -0.10379679368168127, logctail: 3.7700471749674615e-14 }, { invc: 1.1015625, pad: 0, logc: -0.096729626458568418, logctail: 1.7306161136093256e-14 }, { invc: 1.1015625, pad: 0, logc: -0.096729626458568418, logctail: 1.7306161136093256e-14 }, { invc: 1.09375, pad: 0, logc: -0.089612158689647003, logctail: -4.0129135527265743e-14 }, { invc: 1.0859375, pad: 0, logc: -0.082443669211102133, logctail: 2.7541708360737882e-14 }, { invc: 1.0859375, pad: 0, logc: -0.082443669211102133, logctail: 2.7541708360737882e-14 }, { invc: 1.078125, pad: 0, logc: -0.075223421237637922, logctail: 5.0396178134370583e-14 }, { invc: 1.078125, pad: 0, logc: -0.075223421237637922, logctail: 5.0396178134370583e-14 }, { invc: 1.0703125, pad: 0, logc: -0.067950661908525944, logctail: 1.8195060030168815e-14 }, { invc: 1.0625, pad: 0, logc: -0.060624621816486979, logctail: 5.2136206391365041e-14 }, { invc: 1.0625, pad: 0, logc: -0.060624621816486979, logctail: 5.2136206391365041e-14 }, { invc: 1.0546875, pad: 0, logc: -0.053244514518837605, logctail: 2.532168943117445e-14 }, { invc: 1.0546875, pad: 0, logc: -0.053244514518837605, logctail: 2.532168943117445e-14 }, { invc: 1.046875, pad: 0, logc: -0.045809536031242715, logctail: -5.1488495726858107e-14 }, { invc: 1.046875, pad: 0, logc: -0.045809536031242715, logctail: -5.1488495726858107e-14 }, { invc: 1.0390625, pad: 0, logc: -0.038318864302141264, logctail: 4.6652946995830086e-15 }, { invc: 1.0390625, pad: 0, logc: -0.038318864302141264, logctail: 4.6652946995830086e-15 }, { invc: 1.03125, pad: 0, logc: -0.03077165866670839, logctail: -4.5298142577909288e-14 }, { invc: 1.03125, pad: 0, logc: -0.03077165866670839, logctail: -4.5298142577909288e-14 }, { invc: 1.0234375, pad: 0, logc: -0.023167059281490765, logctail: -4.3613240678515679e-14 }, { invc: 1.015625, pad: 0, logc: -0.015504186535963527, logctail: -1.7274567499706107e-15 }, { invc: 1.015625, pad: 0, logc: -0.015504186535963527, logctail: -1.7274567499706107e-15 }, { invc: 1.0078125, pad: 0, logc: -0.0077821404420319595, logctail: -2.2989410046203511e-14 }, { invc: 1.0078125, pad: 0, logc: -0.0077821404420319595, logctail: -2.2989410046203511e-14 }, { invc: 1, pad: 0, logc: 0, logctail: 0 }, { invc: 1, pad: 0, logc: 0, logctail: 0 }, { invc: 0.9921875, pad: 0, logc: 0.0078431774610407956, logctail: -1.4902732911301337e-14 }, { invc: 0.984375, pad: 0, logc: 0.015748356968174448, logctail: -3.5279803896553249e-14 }, { invc: 0.9765625, pad: 0, logc: 0.023716526617363343, logctail: -4.7300547720332489e-14 }, { invc: 0.96875, pad: 0, logc: 0.031748698314572721, logctail: 7.5803103693751609e-15 }, { invc: 0.9609375, pad: 0, logc: 0.039845908547249564, logctail: -4.9893776716773285e-14 }, { invc: 0.953125, pad: 0, logc: 0.048009219186383234, logctail: -2.2626293930306741e-14 }, { invc: 0.9453125, pad: 0, logc: 0.056239718322899535, logctail: -2.3456744910186991e-14 }, { invc: 0.94140625, pad: 0, logc: 0.060380510988920832, logctail: -1.3352588834854848e-14 }, { invc: 0.93359375, pad: 0, logc: 0.068713892548089461, logctail: -3.7652968203888748e-14 }, { invc: 0.92578125, pad: 0, logc: 0.077117303344380161, logctail: 5.1128335719851986e-14 }, { invc: 0.91796875, pad: 0, logc: 0.085591930335453981, logctail: -5.0466744384701189e-14 }, { invc: 0.9140625, pad: 0, logc: 0.089856329121857925, logctail: 3.1218748807418837e-15 }, { invc: 0.90625, pad: 0, logc: 0.098440072813218649, logctail: 3.3871241029241416e-14 }, { invc: 0.8984375, pad: 0, logc: 0.10709813555638448, logctail: -1.7376727386423858e-14 }, { invc: 0.89453125, pad: 0, logc: 0.11145544092528326, logctail: 3.9571258997998038e-14 }, { invc: 0.88671875, pad: 0, logc: 0.12022742699821265, logctail: -5.2849453521890294e-14 }, { invc: 0.8828125, pad: 0, logc: 0.12464244520731427, logctail: -3.7670125023087379e-14 }, { invc: 0.875, pad: 0, logc: 0.13353139262449076, logctail: 3.1859736349078334e-14 }, { invc: 0.87109375, pad: 0, logc: 0.13800567301939282, logctail: 5.0900642926060466e-14 }, { invc: 0.86328125, pad: 0, logc: 0.14701474296180095, logctail: 8.7107837961224781e-15 }, { invc: 0.859375, pad: 0, logc: 0.15154989812720032, logctail: 6.1578962291229762e-16 }, { invc: 0.8515625, pad: 0, logc: 0.16068238169043525, logctail: 3.8215777439167963e-14 }, { invc: 0.84765625, pad: 0, logc: 0.16528009093906348, logctail: 3.9440046718453496e-14 }, { invc: 0.83984375, pad: 0, logc: 0.17453941635187675, logctail: 2.2924522154618074e-14 }, { invc: 0.8359375, pad: 0, logc: 0.17920142945774842, logctail: -3.7425300947322631e-14 }, { invc: 0.83203125, pad: 0, logc: 0.18388527877016259, logctail: -2.5223102140407338e-14 }, { invc: 0.82421875, pad: 0, logc: 0.1933193110035063, logctail: -1.0320443688698849e-14 }, { invc: 0.8203125, pad: 0, logc: 0.19806991376208316, logctail: 1.0634128304268335e-14 }, { invc: 0.8125, pad: 0, logc: 0.20763936477828793, logctail: -4.3425422595242564e-14 }, { invc: 0.80859375, pad: 0, logc: 0.21245865121420593, logctail: -1.2527395755711364e-14 }, { invc: 0.8046875, pad: 0, logc: 0.21730127569003344, logctail: -5.2040087434058838e-14 }, { invc: 0.80078125, pad: 0, logc: 0.22216746534115828, logctail: -3.9798445159517019e-15 }, { invc: 0.79296875, pad: 0, logc: 0.2319714654378231, logctail: -4.7955860343296286e-14 }, { invc: 0.7890625, pad: 0, logc: 0.23690974707835721, logctail: 5.0156860137916023e-16 }, { invc: 0.78515625, pad: 0, logc: 0.24187253642048745, logctail: -7.2523189532402926e-16 }, { invc: 0.78125, pad: 0, logc: 0.24686007793150111, logctail: 2.4688324156011588e-14 }, { invc: 0.7734375, pad: 0, logc: 0.25691041378502177, logctail: 5.4651212536247919e-15 }, { invc: 0.76953125, pad: 0, logc: 0.26197371574153294, logctail: 4.1026510716984462e-14 }, { invc: 0.765625, pad: 0, logc: 0.26706278524909521, logctail: -4.9967365023459362e-14 }, { invc: 0.76171875, pad: 0, logc: 0.27217788591576664, logctail: 4.9035807081563468e-14 }, { invc: 0.7578125, pad: 0, logc: 0.27731928541618345, logctail: 5.0896280395007593e-14 }, { invc: 0.75390625, pad: 0, logc: 0.28248725557466514, logctail: 1.1782016386565151e-14 }, { invc: 0.74609375, pad: 0, logc: 0.29290401643288533, logctail: 4.7274529405144063e-14 }, { invc: 0.7421875, pad: 0, logc: 0.29815337231912054, logctail: -4.4204083338755686e-14 }, { invc: 0.73828125, pad: 0, logc: 0.30343042941990461, logctail: 1.5483459934980831e-14 }, { invc: 0.734375, pad: 0, logc: 0.30873548164959175, logctail: 2.1522127491642888e-14 }, { invc: 0.73046875, pad: 0, logc: 0.3140688276249648, logctail: 1.1054030169005386e-14 }, { invc: 0.7265625, pad: 0, logc: 0.31943077076641657, logctail: -5.5343263520706788e-14 }, { invc: 0.72265625, pad: 0, logc: 0.32482161940129117, logctail: -5.351646604259541e-14 }, { invc: 0.71875, pad: 0, logc: 0.33024168687052224, logctail: 5.4612144489920215e-14 }, { invc: 0.71484375, pad: 0, logc: 0.3356912916381134, logctail: 2.8136969901227338e-14 }, { invc: 0.7109375, pad: 0, logc: 0.34117075740277869, logctail: -1.156568624616423e-14 }] };
function top12(x) {
return Number(BigInt.asUintN(32, ($asu64(x) >> BigInt(52))));
}

function zeroinfnan(i) {
return +(BigInt.asUintN(64, BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * i) - BigInt.asUintN(64, BigInt(1))) >= BigInt.asUintN(64, BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * $asu64((Infinity))) - BigInt.asUintN(64, BigInt(1))));
}

function issignaling_inline(x) {
let ix = $asu64(x);
if ($T((+!$T(1)))) return +((BigInt.asUintN(64, ix & BigInt.asUintN(64, 0x7ff8000000000000n))) === BigInt.asUintN(64, 0x7ff8000000000000n));
return +(BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * (BigInt.asUintN(64, ix ^ BigInt.asUintN(64, 0x0008000000000000n)))) > BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * 0x7ff8000000000000n));
}

function checkint(iy) {
let e = Number(BigInt.asIntN(32, BigInt.asUintN(64, (iy >> BigInt(52)) & BigInt.asUintN(64, BigInt(0x7ff)))));
if ($T((+(e < 0x3ff)))) return 0;
if ($T((+(e > (0x3ff + 52))))) return 2;
if (((BigInt.asUintN(64, iy & (BigInt.asUintN(64, (BigInt.asUintN(64, 1n << BigInt((((0x3ff + 52) - e))))) - BigInt.asUintN(64, BigInt(1)))))) !== 0n)) return 0;
if (((BigInt.asUintN(64, iy & (BigInt.asUintN(64, 1n << BigInt((((0x3ff + 52) - e))))))) !== 0n)) return 1;
return 2;
}

function opt_barrier_double(x) {
let y = x;
return y;
}

function __math_divzero(sign) {
let y = (opt_barrier_double(($T(sign) ? -1 : 1)) / 0);
return (y);
}

function __math_invalid(x) {
let y = (((x - x)) / ((x - x)));
return ($T(+Number.isNaN(x)) ? y : (y));
}

function eval_as_double(x) {
return x;
}

function xflow(sign, y) {
y = eval_as_double((opt_barrier_double(($T(sign) ? (-y) : y)) * y));
return (y);
}

function __math_oflow(sign) {
return xflow(sign, 3.1050361846014179e+231);
}

function __math_uflow(sign) {
return xflow(sign, 1.2882297539194267e-231);
}

function log_inline(ix, tail) {
let $m1a, $m1b;
let z, r, y, invc, logc, logctail, kd, hi, t1, t2, lo, lo1, lo2, p;
let iz, tmp;
let k, i;
tmp = BigInt.asUintN(64, ix - BigInt.asUintN(64, 0x3fe6955500000000n));
i = Number(BigInt.asIntN(32, (((tmp >> BigInt(((52 - 7))))) % BigInt.asUintN(64, BigInt(((1 << 7)))))));
k = Number(BigInt.asIntN(32, (BigInt.asIntN(64, tmp) >> BigInt(52))));
iz = BigInt.asUintN(64, ix - (BigInt.asUintN(64, tmp & BigInt.asUintN(64, 0xfffn << BigInt(52)))));
z = $asd(iz);
kd = k;
invc = __pow_log_data.tab[i].invc;
logc = __pow_log_data.tab[i].logc;
logctail = __pow_log_data.tab[i].logctail;
r = $fma(z, invc, -1);
t1 = $fma(kd, __pow_log_data.ln2hi, logc);
t2 = (t1 + r);
lo1 = $fma(kd, __pow_log_data.ln2lo, logctail);
lo2 = ((t1 - t2) + r);
let ar, ar2, ar3, lo3, lo4;
ar = (__pow_log_data.poly[0] * r);
ar2 = (r * ar);
ar3 = (r * ar2);
hi = (t2 + ar2);
lo3 = $fma(ar, r, (-ar2));
lo4 = ((t2 - hi) + ar2);
p = (($m1a = ar3, $m1b = ($fma(ar2, ($fma(ar2, ($fma(r, __pow_log_data.poly[6], __pow_log_data.poly[5])), $fma(r, __pow_log_data.poly[4], __pow_log_data.poly[3]))), $fma(r, __pow_log_data.poly[2], __pow_log_data.poly[1]))), $m1a * $m1b));
lo = $fma($m1a, $m1b, (((lo1 + lo2) + lo3) + lo4));
y = (hi + lo);
tail[0] = ((hi - y) + lo);
return y;
}

function __math_check_oflow(y) {
return ($T(((y) === Infinity ? 1 : (y) === -Infinity ? -1 : 0)) ? (y) : y);
}

function check_oflow(x) {
return ($T(0) ? __math_check_oflow(x) : x);
}

function force_eval_double(x) {
let y = x;
}

function __math_check_uflow(y) {
return ($T(+(y === 0)) ? (y) : y);
}

function check_uflow(x) {
return ($T(0) ? __math_check_uflow(x) : x);
}

function specialcase(tmp, sbits, ki) {
let scale, y;
if ($T((+((BigInt.asUintN(64, ki & BigInt.asUintN(64, BigInt(0x80000000)))) === BigInt.asUintN(64, BigInt(0)))))) {
sbits = BigInt.asUintN(64, sbits - BigInt.asUintN(64, 1009n << BigInt(52)));
scale = $asd(sbits);
y = (5.4861240687936887e+303 * ($fma(scale, tmp, scale)));
return check_oflow(eval_as_double(y));
}
sbits = BigInt.asUintN(64, sbits + BigInt.asUintN(64, 1022n << BigInt(52)));
scale = $asd(sbits);
y = (scale + (scale * tmp));
if ($T((+(Math.abs(y) < 1)))) {
let hi, lo, one = 1;
if ($T((+(y < 0)))) one = -1;
lo = ((scale - y) + (scale * tmp));
hi = (one + y);
lo = (((one - hi) + y) + lo);
y = (eval_as_double((hi + lo)) - one);
if ($T((+(y === 0)))) y = $asd(BigInt.asUintN(64, sbits & 0x8000000000000000n));
force_eval_double((opt_barrier_double(2.2250738585072014e-308) * 2.2250738585072014e-308));
}
y = (2.2250738585072014e-308 * y);
return check_uflow(eval_as_double(y));
}

function exp_inline(x, xtail, sign_bias) {
let $m1a, $m1b;
let abstop;
let ki, idx, top, sbits;
let kd, z, r, r2, scale, tail, tmp;
abstop = ((top12(x) & ((0x7ff) >>> 0)) >>> 0);
if ($T((+(((abstop - top12(5.5511151231257827e-17)) >>> 0) >= ((top12(512) - top12(5.5511151231257827e-17)) >>> 0))))) {
if ($T((+(((abstop - top12(5.5511151231257827e-17)) >>> 0) >= 0x80000000)))) {
let one = ($T(1) ? (1 + x) : 1);
return ($T(sign_bias) ? (-one) : one);
}
if ($T((+(abstop >= top12(1024))))) {
if (((($asu64(x) >> BigInt(63))) !== 0n)) return __math_uflow(sign_bias); else return __math_oflow(sign_bias);
}
abstop = ((0) >>> 0);
}
z = ($m1a = __exp_data.invln2N, $m1b = x, $m1a * $m1b);
kd = eval_as_double($fma($m1a, $m1b, __exp_data.shift));
ki = $asu64(kd);
kd = (kd - __exp_data.shift);
r = $fma(kd, __exp_data.negln2loN, $fma(kd, __exp_data.negln2hiN, x));
r = (r + xtail);
idx = BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * ((ki % BigInt.asUintN(64, BigInt(((1 << 7)))))));
top = BigInt.asUintN(64, (BigInt.asUintN(64, ki + BigInt.asUintN(64, BigInt(sign_bias)))) << BigInt(((52 - 7))));
tail = $asd(__exp_data.tab[Number(BigInt.asIntN(32, idx))]);
sbits = BigInt.asUintN(64, __exp_data.tab[Number(BigInt.asIntN(32, BigInt.asUintN(64, idx + BigInt.asUintN(64, BigInt(1)))))] + top);
r2 = (r * r);
tmp = $fma((r2 * r2), ($fma(r, __exp_data.poly[(8 - 5)], __exp_data.poly[(7 - 5)])), $fma(r2, ($fma(r, __exp_data.poly[(6 - 5)], __exp_data.poly[(5 - 5)])), (tail + r)));
if ($T((+(abstop === ((0) >>> 0))))) return specialcase(tmp, sbits, ki);
scale = $asd(sbits);
return eval_as_double($fma(scale, tmp, scale));
}

function pow(x, y) {
let sign_bias = ((0) >>> 0);
let ix, iy;
let topx, topy;
ix = $asu64(x);
iy = $asu64(y);
topx = top12(x);
topy = top12(y);
if ($T((+($T(+(((topx - ((0x001) >>> 0)) >>> 0) >= (((0x7ff - 0x001)) >>> 0))) || $T(+((((((topy & ((0x7ff) >>> 0)) >>> 0)) - ((0x3be) >>> 0)) >>> 0) >= (((0x43e - 0x3be)) >>> 0))))))) {
if ($T((zeroinfnan(iy)))) {
if ($T((+(BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * iy) === BigInt.asUintN(64, BigInt(0)))))) return ($T(issignaling_inline(x)) ? (x + y) : 1);
if ($T((+(ix === $asu64(1))))) return ($T(issignaling_inline(y)) ? (x + y) : 1);
if ($T((+($T(+(BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * ix) > BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * $asu64((Infinity))))) || $T(+(BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * iy) > BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * $asu64((Infinity))))))))) return (x + y);
if ($T((+(BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * ix) === BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * $asu64(1)))))) return 1;
if ($T((+((+(BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * ix) < BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * $asu64(1)))) === +!(((iy >> BigInt(63))) !== 0n))))) return 0;
return (y * y);
}
if ($T((zeroinfnan(ix)))) {
let x2 = (x * x);
if ($T((+(((ix >> BigInt(63)) !== 0n) && $T(+(checkint(iy) === 1)))))) {
x2 = (-x2);
sign_bias = ((1) >>> 0);
}
if ($T((+($T(+($T(0) && $T(+(BigInt.asUintN(64, BigInt.asUintN(64, BigInt(2)) * ix) === BigInt.asUintN(64, BigInt(0)))))) && ((iy >> BigInt(63)) !== 0n))))) return __math_divzero(sign_bias);
return (((iy >> BigInt(63)) !== 0n) ? opt_barrier_double((1 / x2)) : x2);
}
if ((((ix >> BigInt(63))) !== 0n)) {
let yint = checkint(iy);
if ($T((+(yint === 0)))) return __math_invalid(x);
if ($T((+(yint === 1)))) sign_bias = ((((0x800 << 7))) >>> 0);
ix = BigInt.asUintN(64, ix & BigInt.asUintN(64, 0x7fffffffffffffffn));
topx = ((topx & ((0x7ff) >>> 0)) >>> 0);
}
if ($T((+((((((topy & ((0x7ff) >>> 0)) >>> 0)) - ((0x3be) >>> 0)) >>> 0) >= (((0x43e - 0x3be)) >>> 0))))) {
if ($T((+(ix === $asu64(1))))) return 1;
if ($T((+((((topy & ((0x7ff) >>> 0)) >>> 0)) < ((0x3be) >>> 0))))) {
if ($T((1))) return ($T(+(ix > $asu64(1))) ? (1 + y) : (1 - y)); else return 1;
}
return ($T(+((+(ix > $asu64(1))) === (+(topy < ((0x800) >>> 0))))) ? __math_oflow(((0) >>> 0)) : __math_uflow(((0) >>> 0)));
}
if ($T((+(topx === ((0) >>> 0))))) {
ix = $asu64((opt_barrier_double(x) * 4503599627370496));
ix = BigInt.asUintN(64, ix & BigInt.asUintN(64, 0x7fffffffffffffffn));
ix = BigInt.asUintN(64, ix - BigInt.asUintN(64, 52n << BigInt(52)));
}
}
let lo = [0];
let hi = log_inline(ix, lo);
let ehi, elo;
ehi = (y * hi);
elo = $fma(y, lo[0], $fma(y, hi, (-ehi)));
return exp_inline(ehi, elo, sign_bias);
}
module.exports = { setheap: h => { H = h; }, image, IMAGE_END, STRUCTS: {"__fsid_t":{"__val":2}}, top12, zeroinfnan, issignaling_inline, checkint, opt_barrier_double, __math_divzero, __math_invalid, eval_as_double, xflow, __math_oflow, __math_uflow, log_inline, __math_check_oflow, check_oflow, force_eval_double, __math_check_uflow, check_uflow, specialcase, exp_inline, pow };
