# Evaluación PluriSwap — espíritu, diseño, implementación

Revisión completa del 2026-09-22, sobre `4db4d68` (F4 cerrada). Cubre `PROTOCOLO.md`, el kernel,
las libraries, los paquetes públicos y privados, los circuitos, el pool, el CI y la suite.
Suite corrida en el momento de la revisión: **558 pass / 0 fail / 10 skipped**.

Todo lo que se afirma acá está verificado contra el bytecode o contra un test adversarial escrito
para la revisión, no contra la spec. Donde hay un número medido, dice cómo se midió.

Este documento es un registro de trabajo, no doctrina: las decisiones que salgan de acá viven en la
Anexo R de `PROTOCOLO.md`. Cada ítem se tacha acá cuando cierra, con el commit que lo cerró.

---

## Veredicto

La calidad de ingeniería es alta y —lo que es raro— **el bytecode respeta el espíritu escrito**.
`Escrow.sol` no tiene owner, no tiene pausa, el constructor está vacío, `_close` es credit-first,
`runPostTerminal` es idempotente de verdad, y la ley de TDD se ve en el historial.

Hay dos brechas estructurales:

1. Entre **lo que el protocolo protege** y **lo que promete** (la discusión A).
2. Entre **lo que está probado** y **lo que está desplegado** (la capa privada entera).

La segunda es trabajo. La primera es una decisión de diseño que todavía no se tomó.

---

## Low hanging fruit

### LHF-1 — `PoseidonT3` no entra en EIP-170; el gate de CI está rojo

```
PoseidonT3  runtime 29,315 B   margin −4,739 B
```

El gate de `.github/workflows/ci.yml` aborta con cualquier contrato de margen negativo, y con
`forge 1.5.1` (la versión pineada) `PoseidonT3` aparece en ese JSON. Los tests pasan porque el EVM
de Foundry no aplica EIP-170 en despliegues de test; Arbitrum sí.

Probado con `runs=1` y `runs=200` bajo `via_ir`: 29,314 / 29,315. El build canónico de upstream sí
entra (initcode pre-firmado de 23,548 B). Fix: no compilar la library en este árbol — usar el
deployment determinístico `0x3333333C0A88F9BE4fd23ed0536F9B6c427e3B93`, como se hizo con `verifiers/`.

**Estado: CERRADO** (2026-09-22, Anexo R). `src/packages/libraries/Poseidon.sol` llama el deployment de
upstream por address y selector; las direcciones se derivan por `CREATE2(0x4e59…, salt, initcode)` del
submodule pineado (`bun poseidon:fixture`, con gate de drift en CI), `script/Poseidon.s.sol` las asegura
en una chain nueva, y toda ruta de hash falla cerrada (`PoseidonUnavailable`) donde el singleton no está.
El gate de bytecode queda en cero contratos por encima del límite. Efecto colateral medido: el build
canónico es mucho más barato que el nuestro —

| | antes | ahora |
| --- | ---: | ---: |
| `insert` depth 32 (primero / siguientes) | 2,23M / 1,3M | **0,93M / 0,65M** |
| deploy del árbol | 1,33M | **1,04M** |
| bundle privado de 3 prepares (un lado) | 9,73M | **7,64M** |

Queda pendiente sólo el resto externo: `PoseidonT2` todavía no está en Arbitrum (sí `PoseidonT3`, en One
y Sepolia), así que el deploy de la capa privada arranca corriendo ese script — se enlaza con LHF-2.

### LHF-2 — La capa privada no tiene deploy script ni deployment

`script/` no menciona `Private*` ni `Poseidon`. `deployments/` no tiene nada privado. El lab tampoco
la conoce. F1–F4 están cerradas *en tests*: la capa que es el valor central del producto nunca tocó
una chain. Es el gap más barato de cerrar y el que más información devuelve (gas real, tamaños
reales, LHF-5).

**Estado: PARCIAL** (2026-09-22, Anexo R). `script/DeployPrivate.s.sol` despliega la capa entera y
**simula limpio contra el estado real de Arbitrum Sepolia**: 68,7M gas en 19 txs, la mayor 7,1M (bien
bajo el límite por tx), ~0,009 ETH. El círculo de wiring —árbol ← reputación ← vault ← reputación— se
rompe por predicción CREATE con assert de que aterrizó, y el wiring quedó separado en `deployStack`
para que `test/DeployPrivate.t.sol` lo ejerza directo con los proofs de register comprometidos: el
wiring desplegado y el testeado no pueden divergir. La corrida contra Sepolia confirmó además lo que
LHF-1 asumía sobre la chain destino (`PoseidonT3` ya está; `PoseidonT2` lo pone el script).

Falta sólo lo que no puedo hacer desde acá: el **broadcast** (necesita la key financiada). El wiring
del lab dejó de ser pendiente el 2026-09-23, cuando la UI salió del repo. Comando:

```sh
HOLDER_PRIVATE_KEY=… forge script script/DeployPrivate.s.sol:DeployPrivate \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast
```

### LHF-3 — Los relojes en cero son un arma cargada sin seguro

Verificado con tests propios:

- `releaseDuration = 0` → el Provider hace `markFiat` + `claim` **en el mismo bloque**, sin fiat y sin
  ventana de disputa. `CLAIMED`, 100% al Provider.
- `fiatDuration = 0` → cualquiera cancela al instante; el Provider que ya pagó fiat se queda sin nada.

El kernel lo permite por diseño (§E.3.8, "único bound: `duration >= 0`"). Pero el lab no advierte nada:
`ConsentPanel.ts` son dos `<input>` de texto con defaults 3600/1800 — y 1800 s para una transferencia
bancaria ya es de por sí muy pro-Provider. Una librería `SaneTerms` del lado cliente más un warning
duro en el firmador cuesta una tarde.

**Estado: CERRADO** (2026-09-22, Anexo R). Resultaron **cuatro**, no dos. Además de los dos de arriba:
`disputeDuration = 0` convierte la única defensa del Holder en un 50/50 instantáneo; `releaseDuration = 0`
además deja `openDisputed` en `TooLate`, así que el Holder no tiene ni el freeze; y
`arbitrationDuration = 0` con ARBITRATION deja forzar el timeout en el bloque en que se abre la corte,
con el court fee ya pagado. Las cuatro pineadas contra el kernel (`test/ZeroClocks.t.sol`,
`Packages.t.sol`), no inferidas de la spec.

El kernel no cambia: `duration >= 0` se queda, porque las duraciones son de las partes y un mínimo de
kernel sería una opinión sobre cuánto tarda una transferencia bancaria. Lo que se agrega es una
obligación de cliente declarada en §E.3.8, que desde el **2026-09-23 se sostiene sola**: cuando se borró
el lab, §E.3.8 se reescribió para enumerar los cuatro peligros, los pisos de producción con su razón, el
techo, y qué relojes quedan inertes bajo `PAYMENT_PROOF` — un cliente conforme se implementa desde la
spec, sin leer código.

Separa dos afirmaciones que no son la misma: *peligro* (un cero — nunca intencional; no se firma sin
reconocimiento explícito, y el reconocimiento se borra si los términos cambian) y *piso de producción*
(un juicio, no protocolo). Las cuatro conductas siguen pineadas contra el kernel por 5 tests de forge,
que es donde importa: si el kernel cambia, fallan los tests y no la prosa.

### LHF-4 — `ROOT_HISTORY = 64` es demasiado chico para un árbol compartido

`src/packages/PoseidonTree.sol:19`. El árbol de cuentas es global: cada `prepare` y cada `claim`
insertan una hoja. Un deal con reputación de dos lados son ~4 inserts. A 64 raíces un proof queda
stale después de **16 deals** — en Arbitrum, potencialmente menos de un minuto entre generar el proof
y landearlo. Es una constante inmutable por deployment: cambiarla ahora cuesta cero.

**Estado: CERRADO** (2026-09-22, Anexo R). Subir la constante sola no alcanzaba: `isKnownRoot`
escaneaba la ventana entera —**139.630 gas medidos** con N=64, lineal desde ahí— en el camino caliente
de siete call sites on-chain, así que una ventana más grande se pagaba a sí misma. Van los dos cambios
juntos: membership por mapping (el ring queda sólo para la evicción) → **3.854 gas**, constante en la
ventana; y `rootHistory` pasa a parámetro inmutable por árbol, acotado a [64, 65536], con default de
protocolo 4096 (~1000 deals de tolerancia). Costo: +6% en el insert (633.927 → 672.018 a depth 32),
que corre ~4 veces por deal contra 6–8 lecturas. Los circuitos no cambian: la prueba sigue siendo
contra *una* raíz; quién la acepta es del contrato. Que agrandar no debilita nada quedó explícito en
§E.3.15.3 — la ventana es liveness, el replay lo cortan los nullifiers.

### LHF-5 — El bundle de activación privada es enorme

Medido con proofs reales instrumentando `test/VaultRealProof.t.sol`:

```
BUNDLE 3-prepare gas (un solo lado): 7,638,535   (9,729,712 antes de cerrar LHF-1)
```

Un deal privado de dos lados exige los seis prepares **más** `activate` en una sola tx atómica
(§E.3.15.4): **~15M de gas** y ~54 KB de calldata (seis proofs UltraHonk de ~9 KB cada uno,
`test/fixtures/proofs/*.json`). Para un deal T1 con cap de 250 USDC, el costo de la privacidad puede
acercarse al valor del trade. No es un bug: es consecuencia del diseño atómico. Pero es un dato que
falta al lado de las cotas de gas de `verify` en §E.3.15.11, porque decide si la capa privada es usable
en el segmento que más la necesita.

**Estado: MEDIDO (2026-09-23), y el dato que faltaba estaba mal.** El primer hallazgo es que las
cifras publicadas de `verify` (1,7–2,1M por adapter) eran **un artefacto de medición**: los tests
construían el blob del proof con un cheatcode de lectura de archivo adentro de la ventana de
`gasleft()`, y eso son ~1,1M de forge que la EVM nunca gastó. Medido limpio, un verify de UltraHonk
cuesta **0,67–0,75M**, casi sin importar el circuito que tenga detrás:

| verify | gas | verify | gas |
| --- | ---: | --- | ---: |
| humanity | 708k | bond | 732k |
| account | 680k | deposit | 665k |
| passport | 717k | claim | 746k |
| admit | 730k | reabsorb | 685k |
| | | withdraw | 708k |

Lo que cambia la conclusión: **el costo de un deal privado no está en verificar**. Los seis proofs del
bundle suman 4,36M; el bundle de un solo lado mide 7,64M, así que lo que domina son los **inserts de
Merkle** (0,93M el primero de un árbol, 0,65M los siguientes, depth 32) más el trabajo del kernel.
Optimizar apunta ahí, no a los proofs.

El calldata sí era correcto y es el otro eje: **53.824 bytes** medidos para el bundle de seis
(`test_privateDeal_costModel` en VaultRealProof). En un rollup eso es lo que llega a L1, y un proof es
alta entropía, así que la compresión casi no lo toca.

**Las palancas, medidas (2026-09-23, `test/PrivateGas.t.sol` + `test_lever_bundleDecomposition`).**
El 7,64M del bundle tenía el mismo defecto que los verifies: era la cifra por test de forge, que
cuenta los cheatcodes que leen fixtures del disco. Medido con todo hoisteado:

| pieza | gas |
| --- | ---: |
| `passport.prepare` (verify 717k + firma + storage) | 779k |
| `reputation.prepare` (verify 730k + spend 24k + insert 673k + storage) | 1.811k |
| `reputation.admit` (sin proof) | 29k |
| **un lado, PASSPORT+REP** | **2.619k** |

Así que una activación privada de dos lados con PASSPORT+REP es **~5,2M más el `activate` del kernel**,
no ~15M. Con BONDS suma el prepare del vault (~732k de verify + 438k de insert + storage).

Y las tres palancas, con su precio:

| palanca | medido | ahorro en un deal de dos lados |
| --- | --- | ---: |
| Profundidad del árbol de cuentas | **19.539 gas por nivel** (steady); insert depth 32 = 673k, depth 26 = 555k | 32→26: **234k** (2 inserts), y 26 direcciona 67M de cuentas |
| Inserts que comparten camino | 4 inserts sueltos = 2,73M; los mismos 4 hoja-a-hoja son 128 hashes contra **37** batcheados | ~**600k** (dos hojas adyacentes por árbol) |
| Agregación de proofs (recursión) | 4 verifies de 0,72M = 2,9M, el 51% del total | hasta **~2,2M** si el bundle lleva un proof recursivo en vez de cuatro |

Orden de rendimiento: la recursión es la palanca grande y la más cara de construir; el batch de
inserts es la mejor relación esfuerzo/ahorro; la profundidad es casi gratis pero decide cuántas
cuentas direcciona el protocolo para siempre. El nullifier (24k) y el `admit` (29k) son ruido.

**Hecho (2026-09-23): el batch dentro de la activación.** `PoseidonTree.insertMany` hashea una sola vez
todo lo que está arriba del subárbol común (dos hojas: 1.351k → 745k; cuatro: 2.702k → 788k, o sea que
cuatro cuestan apenas más que dos), y `PrivateReputation.prepareBoth` toma los dos lados de una
activación en una llamada. Medido punta a punta: **1.972k → 1.081k, 891k de ahorro** — más que el
insert solo, porque también se ahorra el segundo `isKnownRoot`, la segunda escritura del ring de raíces
y el calldata repetido. Efecto lateral que vale por sí mismo: sin insert entre los dos lados, **los dos
proofs se construyen contra la misma raíz**, así que se pueden generar en paralelo off-chain en vez de
en secuencia.

**Lo que NO hace**: batchear entre deals distintos. Eso pide la cola diferida que habilita la
consistencia eventual, y ahí el incentivo es estructural —el árbol es append-only, así que flushear tu
hoja obliga a insertar las que están adelante— pero el ahorro sigue siendo un bien público: un usuario
racional flushea el prefijo mínimo y paga lo mismo que hoy. Por eso el flush lo paga el protocolo, con
el `activationFee` que ese mismo deal ya cobró.

**La traducción a plata, y la conclusión que ordena todo lo demás.** Con los gases medidos, ETH a
3.500 y los dos ejes de un rollup separados:

| | quieto | cargado |
| --- | ---: | ---: |
| **L2, ejecución** (activación de dos lados, ~4,3M) | $0,15 *(0,01 gwei)* | $1,50 *(0,1 gwei)* |
| **L1, datos** (54 KB de proofs, vía blob) | $0,19 *(1 gwei)* | $18,84 *(100 gwei)* |

En reposo los dos ejes son comparables; con el blob caro **L1 domina 12 a 1**, y es el eje volátil. O
sea: *el costo de la privacidad no es el gas de ejecutar, es el tamaño de los proofs*.

Eso reordena las palancas por valor, no por esfuerzo:

| palanca | ahorro por deal | ataca |
| --- | ---: | --- |
| **Recursión** (un proof agregado en vez de seis) | ~$0,70 quieto, **~$16 cargado** | los dos ejes: 54 KB → ~9 KB y 2,9M → ~0,7M |
| Cola diferida entre deals | $0,04 quieto, $0,40 cargado | sólo L2 |
| Profundidad del árbol 32 → 26 | $0,01 quieto, $0,08 cargado | sólo L2 |

**La recursión vale ~40 veces la cola.** Lo hecho hasta acá (el mux de `compute_root`, `insertMany`,
`prepareBoth`) ya se llevó lo barato del eje L2; lo que queda de ese lado son centavos. La cola
diferida, con toda su latencia y su discusión de incentivos, ahorra menos que el ruido del precio del
blob.

**Requisito de despliegue, si alguna vez se construye la cola.** El flush lo paga el protocolo, y el
peor caso —un flush solitario, sin lote— son 2 × 673k = 1,35M de L2 por deal: $0,05 a 0,01 gwei, $0,47
a 0,1. El `activationFee` tiene que cubrir **ese** número y no el promedio: así cada hoja paga su
propio insert de peor caso al activarse, y negarnos el batching deja de ser un ataque posible. Es la
misma lógica del bond — se calibra contra quien se porta mal, no contra el caso normal.
`activationFee >= 2 · insertGas(depth) · gasPrice · precioETH / precioToken`.

**La recursión, medida (2026-09-23) — y descartada.** El toolchain pineado la soporta: bb 6.0 tiene
`--verifier_target noir-recursive`, y `std::verify_proof_with_type` compila contra un proof recursivo
**no-ZK** de 410 campos con vk de 115 y `proof_type = 0` (la variante ZK, 458 campos, la rechaza el
UltraBuilder; los tamaños son CONSTANTES, no dependen del circuito interno). Lo que la descarta es el
precio:

| | gates | tiempo de prueba (24 hilos) |
| --- | ---: | ---: |
| `claim`, el circuito más grande que tenemos | 122.055 | 753 ms *(medido)* |
| **una** verificación recursiva adentro de un circuito | **681.097** | ~4,2 s |
| agregador de los seis proofs del bundle | ~4.086.582 | **~25 s** |

Veinticinco segundos en un desktop de 24 hilos; en un browser o un teléfono, minutos. Se ahorra ~$16
de blob en un pico, y se lo cobramos al usuario en espera cada vez que activa.

**Lo que sí conviene, y salió de medir la recursión: FUSIONAR, no agregar.** Los tres circuitos de un
lado suman 135.933 gates — *menos de un cuarto de una sola verificación recursiva* — y encima
`prepare_passport` y `prepare_admit` prueban **la misma membresía de la misma hoja bajo la misma
raíz**, así que el fusionado real es más chico que esa suma. Un proof por lado en vez de tres:

| | hoy | fusionado |
| --- | ---: | ---: |
| proofs por activación | 6 | **2** |
| calldata a L1 | 53.824 B | **~18.000 B** |
| gas de verificación | 4,36M | **~1,5M** |
| tiempo de prueba por lado | ~0,9 s (tres proofs) | **~0,8 s** |

Gana en los cuatro ejes a la vez, incluido el que la recursión empeora.

**Construido y medido (2026-09-23): `crates/prepare_side`.** La estimación era 136k gates; el
fusionado real son **89.739**, un 34% menos que la suma, porque la fusión borra la duplicación en vez
de esconderla (tres `dealSubject` en uno, dos membresías de la misma hoja en una). El bond queda
opcional enmascarado por `lockCommit != 0`, la misma señal con la que §E.3.14.7 ya elige la columna del
cap, y hay un test negativo que ancla lo que la máscara no puede aflojar: un lado bonded sigue
necesitando su note viva.

| por activación de dos lados | hoy | `prepare_side` |
| --- | ---: | ---: |
| proofs | 6 | **2** |
| calldata a L1 | 53.824 B | **19.200 B** *(medido, −64%)* |
| gas de verificación | 4,36M | **~1,50M** |
| tiempo de prueba por lado | ~839 ms | **~554 ms** |

**Integrado (2026-09-23).** El `BundleVerifier` verifica una vez y deja un ticket en storage
transitorio bajo el hash de los inputs; los tres módulos piden el ticket en vez de verificar cada uno,
y después exigen lo suyo de esos mismos inputs. Medido por lado:

| | gas |
| --- | ---: |
| `bundle.verify` (una vez, todo el lado) | 745.008 |
| `passport.prepare` (ticket + firma + storage) | 64.349 |
| `reputation.prepare` (ticket + spend + insert + storage) | 1.085.634 |
| `reputation.admit` | 29.257 |
| **un lado, total** | **1.924.248** |

El ticket repetido cuesta **3.069** contra los ~730k de una verificación, que es lo que hace viable
que tres módulos pregunten. Y con el `passport.prepare` en 64k se ve el efecto: el módulo que antes
pagaba una verificación entera ahora paga una consulta.

Quedaron borrados los seis contratos que el merge dejó muertos (tres adapters, tres interfaces) más
sus tres mocks y sus tres verifiers generados. Los circuitos `prepare_passport`, `prepare_admit` y
`prepare_bond` siguen existiendo con sus tests —la afirmación de cada uno sigue siendo cierta y vale
tenerla pineada— pero ya no se verifica ninguno on-chain.

**Cerrado (2026-09-23): el número completo.** Con el kernel medido (`activate` de un deal Core, sin
paquetes: **434.823**) y la activación privada de dos lados compuesta —todo menos la verificación,
medido con mocks, más las dos verificaciones reales medidas contra el fixture comprometido:

| | gas |
| --- | ---: |
| kernel + módulos + árboles (dos lados) | 2.066.946 |
| dos verificaciones reales | 1.490.538 |
| **activación privada de dos lados** | **3.557.484** |
| un deal Core, para comparar | 434.823 |

O sea: **la privacidad cuesta ~8x un deal común**, y el número que esta discusión abrió como "~15M" es
**3,56M**. En plata, con los dos ejes:

| | quieto | cargado |
| --- | ---: | ---: |
| L2 (3,56M) | $0,13 | $1,25 |
| L1 (19.200 B por blob) | $0,07 | $6,72 |
| **total** | **$0,19** | **$7,97** |

Contra los $0,34 / $20,35 con los que empezó la medición. Un deal Core, en la misma escala: $0,015 a
$0,15.

**Lo único que queda es el precio real**, que depende de ETH, del gas de L2 y del blob, y sale de una
chain, no de una tabla de supuestos. El desglose de gas ya no tiene huecos.

### LHF-6 — Kleros: whitelist y pineado son camino crítico y son externos

`openCourt` revierte en Arbitrum One hasta que la gobernanza de Kleros liste el adapter: semanas de
calendario ajeno. `KLEROS_POLICY.md` está listo para pinear. Empezar el trámite ahora, no al final.

**Estado:** abierto (externo), **ya no camino crítico (2026-09-29)**: el tribunal oficial pasó a ser el
panel de uno o tres árbitros (`ArbiterRegistry`, PROTOCOLO.md §E.3.14.4). **Cerrado (2026-09-29):** Kleros
salió del repo; no hay trámite que hacer.

### LHF-7 — El verifier del slot ZK del kernel sigue siendo un mock

`VerifierMock` acepta cualquier `abi.encode(dealId, nullifier)`. Once circuitos Noir construidos,
ninguno es el *payment proof*. No es una tarea: es la decisión de prioridad de la discusión B.

**Estado:** abierto. **Precondición cerrada (2026-09-24):** los términos no firmaban la pata fiat, así
que ningún circuito real habría tenido contra qué verificar el pago — el Provider podía probar *un* pago
cualquiera. Ahora `DealTerms.fiatCommit` la firma oculta (§E.3.13), `Packages.resolve` rechaza un deal ZK
sin ella, y el preimage canónico vive en `pluri_commitments` con vectores. Lo que queda es el circuito
del rail. **El módulo real existe (2026-09-24):** `PaymentProof` arma el claim desde el kernel y consume
el nullifier; `IPaymentVerifier` es la frontera del rail. El único mock que queda es el verifier del rail.

### LHF-8 — Warts menores

- El lab ofrece `markFiat`/`claim`/`openDisputed` en deals ZK; revierten `EdgeOff` (§E.5.6).
- `attest_base`/`reveal_advanced` solo se verifican corriendo el binario `bb` pineado. Para un listado
  en browser falta el path bb.js/WASM.
- `postPending` de reputación nunca llega a cero si el módulo rechaza permanentemente
  (`AlreadyPending`). Es deliberado (§E.3.12.4), pero no hay evento ni métrica que lo exponga.

**Estado: PARCIAL** (2026-09-22, Anexo R). Dos de tres cerrados.

*ZK en el lab*: el wart ya estaba desactualizado cuando lo encontré — los predicados apagaban los
cuatro verbos que el kernel guarda con `_requireNotZk`; lo que faltaba era la prueba, y se agregó un
test de paridad contra la lista del kernel. Moot desde el 2026-09-23: la UI salió del repo. Lo que
sobrevive es la lista del kernel, que es lo que cualquier cliente futuro tiene que espejar.

*Observabilidad de `postPending`*: dos eventos. `PostTerminalPending(dealId, pending)` cada vez que la
deuda cambia, incluido el cero que le dice al keeper que pare (un terminal limpio no emite nada), y
`BondDisposalAbandoned(dealId, vault)` en el fail-open de TRUST-03 — hace falta aparte porque limpia
el bit **igual que un éxito**, y `postPending == 0` no distingue "se entregó" de "el lock se perdió
para siempre". Escrow 16.448 → 16.526 B.

*bb.js/WASM en browser*: sigue abierto. No es un wart, es un pedazo de trabajo.

---

## Las discusiones largas

### A. El stalemate 50/50 le paga al que no puso nada, y el Provider no tiene escalación

Verificado con un test adversarial:

```
Provider paga fiat → markFiat
Controller abre DISPUTED (gratis en Core, ~1% con el paquete oficial)
Provider intenta openCourt  → revert (Unauthorized; §E.3.12.2: "Sólo el Controller abre corte")
Provider intenta claim      → revert (DISPUTED mata el claim)
Provider fuerza stalemate   → STALEMATE, holderAmt 500000, providerAmt 500000
```

El máximo que un Provider que **cumplió al 100%** puede forzar unilateralmente es el 50%. El camino
hacia ahí es unilateral y barato para el otro lado: `openDisputed` es una opción sin bond que
convierte una victoria del Provider en un 50/50. Con BONDS el atacante pierde su 10% y sigue ganando
~40% del principal. Con ARBITRATION seleccionada **tampoco cambia**: abrir corte también es
Controller-only, así que el Controller controla el freeze *y* la escalación.

El principio principio 6 lo justifica con *"ambas partes tenían salida y ninguna la tomó"*. Pero la única
salida del Provider requiere la firma de su contraparte. La simetría que justifica el 50/50 no existe.

Y el 50/50 no es neutral en un escrow: el Holder puso el 100% del capital, el Provider puso cero
on-chain. Un default de 50/50 en un he-said-she-said transfiere sistemáticamente valor del que
custodia al que reclama, en las dos direcciones.

Salidas posibles, ninguna gratis:

1. **Dejar que el Provider abra corte** (bump de kernel). La más directa y la que menos rompe el
   espíritu: el catálogo de rulings sigue cerrado, el adapter sigue sin mover custodia.
2. **Bonds simétricos y grandes** (≥50%) como condición del set oficial. Mata el ataque
   económicamente y mata también el acceso: un T1 con cap 250 tendría que trabar 125.
3. **Stalemate no-50/50**, función de quién tenía la carga. Más honesto respecto de "el dinero se
   mueve con culpa probada", pero abre otros juegos.
4. **Declarar Core-only no apto para trade real** y hacer ARBITRATION o ZK efectivamente obligatorias
   en el set oficial. Coherente con la arquitectura opt-in, pero choca de frente con principio 2
   (*"Core no es un modo degradado: es el recinto"*).

Hoy Core **sí** es un modo degradado y la spec dice lo contrario. Esa es la entrada que falta en la
Anexo R.

**Estado: CERRADA** (2026-09-22, Anexo R). La decisión del equipo tiene dos partes y ninguna es la
que yo había puesto primero en la lista:

1. **Quién abre no se toca.** Sólo el Controller, y no se reabre. El razonamiento que lo sostiene es
   correcto una vez que existe (2): el Provider no necesita disputar, porque contra un Controller
   *ausente* el release deadline le paga el 100% sin permiso de nadie.
2. **Abandonar una disputa la pierde.** El timeout de `DISPUTED` deja de ser 50/50 y pasa a un
   terminal propio, `ABANDONED` (valor 11), con el principal entero al Provider.

Juntas cierran el agujero sin darle al Provider ningún verbo nuevo: congelar-y-esperar termina
exactamente donde terminaba no congelar, así que la opción sobre el 50% ajeno desaparece. Lo que
queda del freno es lo que tenía que ser — tiempo para acordar o para escalar.

Knock-ons decididos por principio: el completion fee se cobra (cerró un trade, misma lectura que
`CLAIMED`); los bonds se devuelven (el abandono es culpa *asumida*, y pagarle el bond del abandonador
a la contraparte le daría incentivo a estancar toda negociación); la reputación marca `+5` al que
abrió. Consecuencia declarada: `BondAction.Burn` existía **sólo** para este terminal —era el parche
económico contra el 50/50— y se queda sin productor.

**El precio, que está asertado en la suite y no escondido:** en Core-only un Provider que nunca pagó y
rehúsa todo acuerdo ahora se lleva el 100% en vez del 50%. Core no tiene tribunal por construcción y
no puede distinguir las dos historias; la decisión es dejar de fingir que un 50/50 era un juicio. Es
el argumento para ARBITRATION, y principio 6 se reescribió para decir lo que el código hace.

Segunda mitad, de la misma sesión: **un deal con tribunal cuesta pelear**. El contest-open vivía sólo
en el paquete de reputación, así que ARBITRATION sin REPUTATION abría gratis — justo lo que la otra
mitad corregía. El `ICourt` declara ahora su propio `contestFee` y `feeRecipient` dentro de
`PackageId.arbitration`. Se eligió eso antes que acoplar ARBITRATION a REPUTATION (una línea en
`resolve`) porque eso arrastraría un Passport a todo deal que sólo quería tribunal, y la identidad no
debería ser el precio de poder ir a corte.

**Reabierta y re-decidida (2026-09-24).** El forfeit dejaba a Core sin defensa frente a un Provider que
nunca pagó: se llevaba el 100%. La crítica original al 50/50 (el Provider no tiene cómo escalar) no
aplica donde **ninguno** puede escalar porque las partes firmaron no tener tribunal. Ahora el timeout de
`DISPUTED` depende de ARBITRATION: sin tribunal no hay split tras disputar y el deadlock quema el
principal (más los locks y `+10` a cada uno); con tribunal sigue siendo abandono. Anexo R, 2026-09-24.
Medido en `SIMULACIONES.md`: sin tribunal es un equilibrio débil; lo que alinea el largo plazo es el tribunal.

### B. El único cuadrante limpio es el que no está construido

`PAYMENT_PROOF` (§E.3.12.1) es el único perfil sin 50/50: proof → `RELEASED`, sin proof → `CANCELLED`.
Determinista, pre-acordado, sin tribunal, sin doxxeo. Es la respuesta a la discusión A.

Y es lo único que no tiene circuito. Once circuitos Noir para reputación privada, bonds privados y
attestations; cero para probar un pago fiat. La razón es entendible (zkEmail / TLSNotary sobre rails
que cambian es lo más difícil del stack), pero la consecuencia estratégica es dura: **el esfuerzo de
privacidad se invirtió en ocultar la reputación, que es el activo menos valioso, mientras el
mecanismo que elimina la disputa sigue en mock.**

**Avance (2026-09-24): la pata fiat, firmada.** El primer paso hacia el circuito no era el circuito: era
que el deal dijera qué pago se acordó. `DealTerms.fiatCommit = Poseidon(TAG_FIAT, rail, currency, amount,
payee, salt)`, oculto; dominio EIP-712 a `version "2"`. Lo que sigue abierto es la decisión de rail y
tecnología (zkEmail, zkTLS, Open Finance), la política de claves de confianza del verifier, y medir las
gates antes de construir.

### C. La raíz anti-sybil contradice el motivo del protocolo

La §E.1.2 existe contra el KYC y el debanking. La raíz de humanidad es Human Passport: un decoder
**proxy upgradeable y pausable de un tercero** (`0x2050…B43`), cuyos stamps de mayor peso vienen
justamente de exchanges centralizados y proveedores de identidad.

- **Kill switch externo declarado.** Passport puede pausar el decoder y congelar toda admisión nueva.
  Está en §E.5.6 como hallazgo abierto; para un protocolo cuya tesis es "nadie puede cerrar el recinto",
  es una contradicción viva. El vault privado la elimina para `withdraw`, no para `enroll`.
- **El conjunto de anonimato es el padrón de enrolados.** Con montos, timings, token y `dealSubject`
  públicos (§E.3.15.8), la desvinculación es una propiedad de multitud. Con 200 cuentas registradas no
  hay privacidad. Eso no es crítica al diseño: es una condición de lanzamiento que debería estar
  escrita — *por debajo de N cuentas, el modelo de amenaza de §E.3.15.8 no aplica*.

### D. Disputar te doxxea, y el que se doxxea es la víctima

"Disputar = salir a la luz" (principio 4) está aceptado como decisión. Operativamente: la evidencia de Kleros
es pública, permanente y en IPFS, y la evidencia que gana un caso de pago fiat *es* un extracto
bancario con nombre, cuenta y fechas. Quien la publica es la parte estafada. `KLEROS_POLICY.md` pide
redactar lo innecesario, pero lo necesario ya identifica a la persona.

El protocolo protege tu privacidad en todos los deals que salen bien y te la quita exactamente cuando
te estafan. Para el mercado objetivo declarado es el peor momento posible para aparecer en un registro
público permanente. ¿Evidencia sellada? ¿Committee? ¿Pruebas ZK de propiedades del recibo?

**Avance (2026-09-29): committee.** Con el panel, la evidencia la ven los árbitros (uno o tres) que las partes
eligieron al negociar, no un registro público: el protocolo no publica nada del caso más allá del
`dealId`, los votos y el ruling. Lo que no resuelve: el canal de evidencia es off-chain y no está
construido, y el panel la ve entera.

**Avance (2026-09-29): evidencia sellada.** El canal quedó definido (PROTOCOLO.md §E.3.14.4, Anexo R): el
chat del deal es cifrado de extremo a extremo, cada mensaje va firmado y encadenado, y al abrir la corte
una parte lo sella a la clave publicada de cada árbitro (`ArbiterRegistry.encryptionKeyOf`). Ningún
servidor ni registro público lo ve. El panel sigue viéndolo entero, y el cliente lo tiene que avisar
antes de compartir.

### E. No hay mercado

Motor de settlement extraordinario, sin auto. No hay capa de descubrimiento, order book, matching ni
canal de comunicación. Labs es read-only por diseño y explícitamente "sin matching" (Anexo R,
2026-09-20). El "listado" aparece en §E.3.15.7 como consumidor de attestations, pero ningún componente
lo implementa.

Los competidores directos son 90% marketplace y 10% escrow. La decisión de que Labs no haga matching
es legalmente coherente, pero deja un agujero que alguien va a llenar — y quien lo llene se convierte
en la plataforma de facto que el protocolo dice no tener. Conviene decidir a propósito quién es ese.

**Avance parcial (2026-09-23): qué muestra un listado.** No resuelve el mercado, pero fija lo que un
listado *puede* mostrar, que es la precondición de cualquiera que lo construya: lo público son
**agregados** (tier, count como cota, `penaltyBand`) y lo avanzado es **crudo** (count y volume
exactos bajo máscara, penalty siempre). El penalty pasó a ser no ocultable en las dos vistas —
con la cota invertida en el listado (`band_claimed >= band_real`) y fuera de la máscara en el perfil.
La razón es que el tier ya netea el penalty: sin el band, un T2 castigado y un novato honesto se leen
igual. Si esta reputación termina consumiéndose fuera del protocolo (préstamos, otra dapp), esa
distinción es lo primero que van a querer, y es lo único que el circuito no dejaba afirmar honestamente.

**Lo que sigue abierto del lado del consumidor externo:** un attestation ata `repRoot` pero **no ata
deployment**. Quien lea esta reputación desde otra dapp tiene que chequear el root contra el árbol
canónico; contra un clon del contrato, un proof perfectamente válido afirma sobre otro árbol. No hay
hoy un identificador de deployment en los public inputs.

### F. Pérdida de `sk_id` = pérdida total, sin recuperación

Listado como riesgo abierto ("recuperación = trabajo futuro"). Para "toda la humanidad" no es un
riesgo abierto: es descalificante a escala. Perder el secreto pierde reputación **y** los bonds
depositados. Cualquier producto de consumo pierde 1–5% de usuarios por año a claves perdidas. Social
recovery sobre `sk_id`, o al menos separar custodia del bond de custodia de la identidad, es
arquitectura, no UX.

**Cerrada la mitad de abajo (2026-09-23).** Había dos pérdidas distintas metidas en una: perder el
*secreto* y perder el *estado del cliente*. La segunda ya no existe. Todos los salts del protocolo
se derivan menos el del handle (que es libre a propósito), así que con `sk_id` y la chain se
reconstruyen la cuenta (`account.ts`) y el vault entero (`notes.ts`): las notes se derivan en cadena
desde los deposits, que son públicos, siguiendo los nullifiers hacia adelante. Antes, un cliente que
perdía su base de datos perdía los bonds aunque su dueño recordara el secreto perfectamente.

**Corrección (2026-09-29).** La mitad de abajo no estaba entera: el árbol de contrapartes vive adentro
de la hoja y sus hojas son los `S` de las contrapartes, que la chain nunca vio. Un cliente que perdía su
estado no podía probar el siguiente `claim`, y los locks que ese claim habilita se perdían con él. Desde
el 2026-09-29 cada lado publica en la activación el `S` de la contraparte y el `pair_secret` bajo un pad
que sólo su `sk_id` reconstruye (`RecoveryHints`, `circuits/js/lib/hints.ts`), y el circuito prueba que
el hint abre a lo que usó.

**Lo que sigue abierto es la mitad de arriba**, y es la que da nombre a la discusión: perder `sk_id`
sigue siendo pérdida total. Derivar salts no es social recovery — es la precondición para que
cualquier esquema de recovery tenga algo que recuperar.

### G. Farmeo de reputación por auto-trading

El score es `successCount + volume/UNIT − penalty`. Un deal entre dos wallets propias con dos juegos
de stamps disjuntos genera `+1/+1` a **ambos** sujetos y el principal vuelve a casa; el costo es gas
más `activationFee`. Cinco vueltas de 250 → score 10 → T2. La raíz anti-sybil limita cuántas
identidades, no cuántas veces te tradeás a vos mismo. El keying por token ayuda pero no cierra.

**Estado: CERRADA (2026-09-23).** No detectando al farmer —eso es indetectable por construcción, y
es la propiedad, no la falla— sino cobrándole el precio correcto: el crédito es **una vez por
contraparte**. Una camarilla cerrada satura en su propio tamaño, así que la escalera se paga en
identidades y no en fees. En la capa pública es un mapping; en la privada es un árbol disperso de
contrapartes dentro de la hoja, con el par nombrado por las dos partes a la vez
(`pairId` conmutativo) y publicado cegado por deal, así que la regla **no cuesta linkability**.

Lo que sigue sin cerrar de esta discusión: el piso sigue siendo el Passport. Si conseguir N juegos de
stamps disjuntos es barato, N contrapartes distintas también lo son — sólo que ahora el ataque cuesta
N identidades en vez de 2, que es exactamente donde queríamos empujarlo.

### H. Neutralidad del kernel vs. plataforma de facto

El argumento legal del kernel muerto es sólido. Pero el conjunto real que un usuario toca es:
paquetes oficiales de Labs + frontend de Labs + backend de Labs + fees a la DAO. La neutralidad
protege a `Escrow.sol`; no está claro que proteja a Labs, que por diseño "absorbe la exposición legal
que el kernel no puede tener". Asegurarse de que Labs sepa cuánta exposición absorbe, en qué
jurisdicción, antes del mainnet.

---

## Verificación end-to-end (2026-09-22)

Antes de tocar ZK: el stack entero corre sobre una chain fría. `script/e2e.sh` despliega core →
paquetes → pool → capa privada, camina CASE-CORE-03..15 y verifica los eventos que aterrizaron —
doce terminales, principal conservado en todos, el abandono pagando el pot entero al Provider.

La corrida encontró **dos scripts rotos desde antes de esta revisión**, y ninguno de los dos aparecía
en un unit test porque son fallas de cableado, no de contrato:

- `Paths.s.sol` afirmaba `claim → RELEASED`. Roto desde el 2026-09-12, cuando `CLAIMED` pasó a ser
  terminal propio. Nadie corrió el catálogo Core on-chain en tres meses.
- `PoolDeal.s.sol` pasaba al Sponsor también como controller designado. Roto desde que el vault con
  shares reemplazó a owned v1: un Sponsor ya es agente y `initialize` lo rechaza.

La causa raíz es la misma en los dos: **CI corría `forge test`, que no toca los scripts.** Ahora
corre `script/e2e.sh` en cada push, y un desarrollador corre exactamente lo mismo.

Wart menor encontrado de paso: `forge script` sin `--broadcast` igual ejecuta `vm.writeJson`, así que
una simulación pisa `deployments/`. Los `31337*` pasaron a gitignore (anvil es descartable); los de
Sepolia siguen versionados.

---

## Estado de Sepolia (2026-09-23)

`script/Doctor.s.sol` apuntado al Sepolia que había: **7 fallas de 41** — el escrow sin
`forceDisputeTimeout` *ni* `retryPostTerminal` (anterior incluso a esta rama), la reputación sin los
getters de contest (anterior al 2026-09-17), los dos courts sin `contestFee` (anterior a ayer).

**Ese stack se borró.** No se arregla incrementalmente, y leer un registro stale es peor que no leer
ninguno porque parece autoritativo: alguien apunta un pool a ese escrow, firma contra ese dominio, y
se entera cuando ya hay plata adentro. La historia queda en git. El próximo deploy es el primero
hecho con la cadena entera en un solo comando.

Contra una chain recién construida el mismo doctor da **42 de 42**, que es lo que hace confiable la
lectura sobre Sepolia.

**Cobertura de mocks para Sepolia: completa.** Lo único que no existe ahí tiene stand-in y ya está
cableado — decoder de Passport (`PassportMock` / `PassportDecoderMock`), y nada más: el pool de Stargate V2 USDC es real y está pineado, PoseidonT3 está
vivo, y los verificadores Honk salen de initcode comprometido.

---

## Orden de ataque propuesto

1. LHF-1 (CI verde), LHF-4 (constante), LHF-2 (capa privada en Sepolia), LHF-6 (arrancar el trámite).
2. LHF-3 (guardas de reloj en el lab), LHF-5 (medir el bundle de dos lados en Sepolia, número a la spec).
3. **Antes de cualquier otra cosa:** abrir la discusión A con una entrada nueva en la Anexo R. No se
   puede auditar ni lanzar un escrow cuyo equilibrio de disputa le paga el 50% al que defecciona.
4. Después: decidir si el próximo circuito es un payment proof de un rail fiat real (discusión B).
