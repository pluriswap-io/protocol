# Informe de verificación — 2026-09-23

Estado de la rama `review/low-hanging-fruit`, desde la evaluación del 2026-09-22 hasta acá.
Qué se ejercita, cómo, y qué no.

Los números salen de corridas reales, no de la spec. Donde algo no está cubierto, lo dice.

**Actualización 2026-09-29** (kernel y paquetes de la Anexo R del 2026-09-28/29, sobre `main`).
Suite: **735 pass / 0 fail / 14 skipped** en `forge test`; `nargo test` verde (70 tests en los 12 crates que tienen);
`bun test circuits/js` 94 / 0; `script/e2e.sh` verde, con `Doctor` en cero fallas. Lo que cambió en
esta tabla: cancelar sin presentarse (OUT-05/06) le marca `NoShow` (+5) al Provider, y el timeout del
tribunal (OUT-12) es el deadlock. Nuevo desde este informe: el panel de árbitros (`ArbiterRegistry`,
20 tests con chequeo de solvencia en cada uno, más `PanelHumanity` sobre el passport y la reputación privados, con verifiers mock), los proofs
dentro de `activate` (`CounterpartyBundle` corre el lado de la contraparte en las suites de proofs
reales), fees proporcionales, el mínimo de 250, la reputación de pools (`PoolPrivate`), el
endurecimiento del pool (`PoolHardening`, 11 tests) y los verifiers pineados por hash
(`VerifierPins`, y `Doctor` compara el runtime desplegado).

**Actualización 2026-10-05** (Anexo R del 2026-10-05: el panel se paga con el bond y el pool es un peer;
plan en [`PLAN_BOND_PANEL_POOL.md`](./PLAN_BOND_PANEL_POOL.md)). Suite: **837 pass / 0 fail / 7 skipped** en
`forge test`; `script/e2e.sh` verde, con `Doctor` en cero fallas; `forge build --sizes` sin contratos sobre
EIP-170. Qué se ejercita de lo nuevo, y dónde:

| Regla | Cubierto por |
| --- | --- |
| Panel ⇒ bonds de los dos lados (`BondsRequired`); sin dispute fee; el 30% del lock del perdedor a los que votaron con el ruling, al ganador si nadie votó; `settle` espera la disposición (`BondsPending`) | `ArbiterRegistry.t.sol` (todos los repartos con chequeo de solvencia), `PanelHumanity.t.sol` |
| El kernel deja la parte de la corte en el slash; `Shared` (15% de cada lock) en el acuerdo con la corte abierta y en el ruling 3; una corte que derivó pierde su parte; el reintento conserva `Shared` | `Packages.t.sol` (tests de la parte de la corte y `retryPostTerminal`) |
| El vault guarda la parte (`shareOf`, `collect` sólo del destinatario), recorta el lock privado (`cutOf`) y el reabsorb acuña lo que quedó | `BondVault.t.sol`, `PrivateVault.t.sol`, `VaultRealProof.t.sol` (proof real `reabsorb_cut`: un lock del 85%) |
| El aval publica `poolId`, `operatorTag` y `cpTag` (11 inputs públicos); uno adulterado no verifica | `VouchVerifier.t.sol` (proof real), `PrivacyCommitments.t.sol` (paridad Noir/JS/Solidity) |
| El pool como peer: aval obligatorio del operador registrado y verificado; tier T1, cupo concurrente, columna bond, crédito una vez por Provider, castigos; bond público dentro del NAV; un pool que pierde o gana en corte | `PoolPrivate.t.sol` (stack privado real, verifiers mock), `Pool.t.sol`, `PoolHardening.t.sol` |

Los caminos de `ArbitrationPaths` siguen con `ArbitrationMock`, que no cobra parte del bond (`bondShareBps = 0`):
sus repartos de la tabla de abajo no cambian.

---

## 1. Cobertura de terminales

El kernel tiene ocho estados terminales y catorce outcomes económicos (§E.3.6, §E.3.11). **Los catorce se
ejercitan on-chain**, no sólo en tests.

| Outcome | Estado | Reparto | Cubierto por |
| --- | --- | --- | --- |
| OUT-01 Release del Controller | `RELEASED` | 100% Provider | `Paths` 06 |
| OUT-02 Co-signed release | `RELEASED` | 100% Provider | `Paths` 10, 13 |
| OUT-03 Release por payment proof | `RELEASED` | 100% Provider | `CatalogDeals` (verifier mock) |
| OUT-04 Claim por timeout | `CLAIMED` | 100% Provider | `Paths` 07 |
| OUT-05 Cancel del Provider | `CANCELLED` | 100% Holder; Provider `NoShow` | `Paths` 03, `NoShow.t.sol` |
| OUT-06 Fiat timeout | `CANCELLED` | 100% Holder; Provider `NoShow` | `Paths` 04, `NoShow.t.sol` |
| OUT-07 Mutual cancel | `CANCELLED` | 100% Holder | `Paths` 05, 08, 12 |
| OUT-08 Split dual-firmado | `RESOLVED_SPLIT` | bps firmados | `Paths` 09, 14 |
| OUT-09 Arb holder win | `RESOLVED_BY_ARBITRATION` | 100% Holder | `ArbitrationPaths` |
| OUT-10 Arb provider win | `RESOLVED_BY_ARBITRATION` | 100% Provider | `ArbitrationPaths`, `CatalogDeals` |
| OUT-11 Tribunal rehúsa | `STALEMATE` | 50/50 | `ArbitrationPaths` |
| OUT-12 Arbitration timeout | `STALEMATE` | deadlock: principal quemado, bonds al sink (2026-09-29) | `ArbitrationPaths`, `CourtFailure.t.sol` |
| OUT-13 Deadlock (2026-09-24) | `STALEMATE` | principal quemado, bonds al sink | `Paths` 15 (Core), `ReputationLadder` |
| OUT-14 Dispute abandonado | `ABANDONED` | 100% Provider | `ArbitrationPaths` (con tribunal y bonds) |

Además, cada corrida de `e2e.sh` lee los eventos `Settled` que aterrizaron y verifica que los doce
terminales Core estén ahí y que **cada uno conserve el principal exactamente**.

### Lo que cada camino de arbitraje asserta

No alcanza con llegar al estado: lo que importa es el mapa del kernel de veredicto a plata.
`ArbitrationPaths` chequea cuatro cosas por terminal — quién cobró el principal, dónde fue cada lock
de bond, qué hizo el score, y si el contest se cobró.

| Camino | Principal | Bonds | Reputación |
| --- | --- | --- | --- |
| Holder win | refund entero, **sin** completion fee | lock del Provider → address del Holder | perdedor **+15** |
| Provider win | payout **con** completion fee | lock del Holder → address del Provider | perdedor **+15** |
| Tribunal rehúsa | 50/50 | **vuelven los dos** | **+5 a ambos** |
| Tribunal no contesta | **quemado** (deadlock, 2026-09-29) | **al sink, los dos** | **+10 a ambos** |
| Abandonado con bonds | 100% Provider | vuelven los dos, sink intacto | el que abandonó **+5** |

El tribunal es `ArbitrationMock`, no el panel, **a propósito**: el mock rinde cualquier veredicto a
pedido, que es la única forma de ejercitar un ruling perdedor y un rehúse en la misma corrida. A una
corte real no se le puede pedir que pierda. Lo que se está verificando es el mapa del **kernel**, y
ese mapa no sabe qué corte habló. El panel (`ArbiterRegistry`) tiene su propia cobertura en
`test/ArbiterRegistry.t.sol` y `test/PanelHumanity.t.sol`. El adapter de Kleros, que tenía cobertura en
fork contra el KlerosCore de Sepolia, se borró del repo el 2026-09-29.

## 2. La reputación

Es la única parte cuyo comportamiento es una **curva** y no una transición, así que ningún deal
suelto la muestra. `ReputationLadder` la camina y la narra. Números medidos:

| Deals cerrados al tope | Score | Cap |
| ---: | ---: | ---: |
| 0 | 0 | 250 |
| 5 | 10 | 500 |
| 10 | 25 | 1.000 |
| 15 | 50 | 2.000 |
| 21 | 104 | sin límite |

Tres cosas que sólo se ven corriéndola:

- **El cap es concurrente, no por deal.** `inFlight + principal <= cap` corre contra todo lo abierto.
  En T2: un deal de 500 o dos de 250, nunca dos de 500. La escalera lo demuestra pidiendo un tercer
  deal de 1 token con el cap lleno.
- **Un deal al tope vale 2 puntos**, porque el cap de T1 *es* el `UNIT` del score. Y el ritmo se
  acelera solo: a cap más alto, más volumen por deal.
- **Lento de ganar, rápido de perder.** Un abandono o un stalemate resta 5 y baja de tier en el acto:
  score 14 → 9, cap 500 → 250.

Y una propiedad que el diseño implica pero que no estaba escrita: en un dispute abandonado la
contraparte cobra el principal entero **y** el mismo crédito de reputación que un trade limpio (+2),
mientras el que abandonó pierde 5 — un swing de 7 puntos. No es vector de farmeo (un release limpio
da +2 a los dos lados y sale más barato), pero sí es un incentivo a no aceptar acuerdos si esperás
que el otro abandone.

## 3. Cómo se verifica

| Gate | Qué cubre | Resultado |
| --- | --- | --- |
| `forge test` | unit + fuzz (256) + invariants (32×256) | **596 / 0**, 14 skipped |
| Perfil `ci` (nightly) | fuzz 2048, invariants 128×512 | **595 / 0** |
| `script/e2e.sh` | despliega el stack entero sobre una chain fría, camina todos los caminos, lee los eventos, audita con el doctor | verde, **42/42** |
| `test/fork/*` | Arbitrum One y Sepolia vivos: decoder de Passport, KlerosCore (disputa real), singletons Poseidon | 13 / 0, 1 skip sin `HUMAN_WALLET` |
| Slither `--fail-medium` | análisis estático | 11 findings, **los mismos que `main`** |
| `bun test circuits/js` | consumer side de F4 | 32 / 0 |
| Gates de drift | vectors de circuits + fixture Poseidon | sin drift |
| `forge build --sizes` | EIP-170 | cero contratos sobre el límite |

`script/e2e.sh` corre los diez scripts en orden sobre anvil, y con `RPC_URL` + `DEPLOY_KEY` apunta a
una chain real (ahí además corre la rampa Stargate, el único componente sin camino en anvil).

## 4. Lo que **no** está cubierto

Dicho explícitamente, porque un informe que sólo lista lo verde es propaganda.

- **La capa privada registra una cuenta on-chain, pero no corre un deal.** Desde el 2026-09-23
  `script/PrivateRegister.s.sol` registra la cuenta de muestra con los proofs comprometidos, así que
  hay una cuenta privada real en la chain y el indexer del prover tiene qué leer. Lo que sigue sin
  correr es un *deal* privado: el `dealId` del kernel se deriva de los terms y las nonces, así que los
  proofs comprometidos no sirven para un deal arbitrario — hace falta el prover, que está a medias
  (`lib/tree.ts` + `lib/indexer.ts` leen el estado; faltan los witness builders y correr `bb`).
- **Los salts de las *notes* siguen libres.** El de la hoja de cuenta se deriva y el circuito lo
  exige desde el 2026-09-23, así que una cuenta se recupera desde `sk_id` solo — está demostrado
  contra una chain, no afirmado. Los notes del vault no: un bond todavía se recupera desde el
  estado local del cliente. Mismo arreglo, circuitos distintos.
- **El verifier del rail del slot ZK es un mock.** El módulo es real (`PaymentProof`, 2026-09-24) y
  arma el claim desde el kernel; `PaymentVerifierMock` cree cualquier blob que nombre ese claim. No
  hay circuito de payment proof todavía; es el próximo trabajo grande.
- **El panel no se ejercita en el e2e con humanidad.** `DeployPrivate` lo despliega con la regla de
  humanidad y `Doctor` audita el cableado, pero un deal privado con panel sólo corre en tests
  (`PanelHumanity`), por la misma razón que el deal privado de arriba: falta el prover.
- **Ningún deal de pool corre con proofs reales (2026-10-05).** El aval nuevo (operador y `cpTag`) se
  verifica con su proof real en `VouchVerifier.t.sol`, pero el deal de pool de punta a punta usa
  verifiers mock. El fixture de `vouch` nombra el pool de muestra `0x9001…9001`: un test con proof real
  del lado del pool tiene que desplegarlo en esa address. Tampoco hay todavía un prover que arme el
  aval ni el `operatorTag` del Controller.
- **El panel nuevo no corre en el e2e.** `DeployPrivate` lo despliega pineando el vault y `Doctor` lo
  audita, pero un deal con panel y bonds sobre el stack privado sólo corre en tests.
- **Auditoría de circuitos** antes de mainnet. Tocan dinero.
- **Aderyn** es el único gate de CI que no corrí localmente.
- **Nada está desplegado.** El stack de Sepolia se borró el 2026-09-23 por estar derivado; el próximo
  deploy es el primero hecho con la cadena entera en un comando.

## 5. Decisiones tomadas en el camino

Todas quedan fechadas en la Anexo R de `PROTOCOLO.md`. Las de fondo:

1. **Abandonar una disputa la pierde** (2026-09-22). El timeout de `DISPUTED` deja de ser 50/50 y
   pasa a `ABANDONED`, con el principal entero al Provider. Cierra la opción gratis que tenía el lado
   Holder sobre la mitad del principal ajeno, sin darle al Provider ningún verbo nuevo. Quién abre
   una disputa no cambió: sigue siendo sólo el Controller.
2. **Un deal con tribunal cuesta pelear** (2026-09-22). El `ICourt` declara su propio `contestFee`
   dentro de su `packageId`, en vez de acoplar ARBITRATION a REPUTATION — que habría arrastrado un
   Passport a todo deal que sólo quería corte.
3. **Poseidon por deployment, no por library** (2026-09-22). El árbol privado no era desplegable:
   compilado acá, `PoseidonT3` pasa EIP-170 por 4.739 bytes. Efecto medido no previsto: el insert
   quedó 58% más barato.
4. **Ventana de raíces 64 → 4096, con lookup O(1)** (2026-09-22). `isKnownRoot` de 139.630 a 3.854
   gas.
5. **Fuera la UI** (2026-09-23), y §E.3.8 reescrita para sostenerse sola, porque declaraba una
   obligación de cliente que apuntaba a un archivo del lab.

## 6. Lo que encontró la verificación

Tres cosas rotas que ningún test unitario veía, porque son fallas de **cableado**:

- `Paths.s.sol` afirmaba `claim → RELEASED`. Roto desde el 2026-09-12, cuando `CLAIMED` pasó a ser
  terminal propio. Nadie había corrido el catálogo Core on-chain en tres meses.
- `PoolDeal.s.sol` pasaba al Sponsor también como controller designado. Roto desde que el vault con
  shares reemplazó a owned v1.
- `DeployKlerosPackages` desplegaba el court con `contestFee = 0`, contradiciendo la decisión del día
  anterior. Ése lo había introducido yo.

La causa raíz de los dos primeros es la misma: **CI corría `forge test`, que no toca los scripts.**
Ahora corre `script/e2e.sh`.
