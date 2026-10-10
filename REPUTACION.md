# Reputación verificable

Qué muestra el perfil de una cuenta, qué de eso no se puede falsificar, y qué te toca chequear a vos.

Este archivo está afuera de `PROTOCOLO.md` por la misma razón que `PANEL_POLICY.md`: su lector no es
quien diseña el protocolo sino quien **consume** esta reputación — un frontend que arma un listado,
otra dapp que la quiere leer, un integrador que necesita saber en qué creer. El detalle normativo
vive en [`PROTOCOLO.md`](./PROTOCOLO.md) §E.3.15.7 (divulgación) y §E.3.15.9 (circuitos); acá está lo
que hace falta para usarla sin leer las 1.200 líneas de la spec.

---

## 1. El problema

Una reputación útil exige historia. Una historia pública exige un registro que cualquiera puede
indexar, y ese registro es exactamente lo que este protocolo existe para no tener: quién comerció
con quién, cuánto, cuándo y con qué wallet.

La salida es que **la cuenta prueba cosas sobre sí misma en vez de que alguien las publique**. No
hay perfil que scrapear. Hay una hoja en un árbol Merkle que sólo el contrato escribe, y su dueña
puede emitir pruebas de lo que esa hoja dice, eligiendo cuánto dice cada una.

De ahí salen dos vistas, y toda la tensión del diseño está en el reparto entre ellas:

> **Lo público son agregados. Lo avanzado es crudo.**

---

## 2. Las dos vistas

| | **Listado** (`attest_base`) | **Perfil** (`reveal_advanced`) |
| --- | --- | --- |
| Quién lo ve | cualquiera, en el listado | sólo a quien se lo entregan |
| Verificada (Passport) | **exacto**: sí / no | — |
| Tier | ordinal 1–5, del **crédito** | — |
| Deals completados | cota inferior (`≥ 21`), del **registro** | **exacto**, si lo elige |
| Volumen | escalón de lotes (`250+`), del **registro** | **exacto**, si lo elige |
| Castigo | escalón de eventos (band 0–3) | **exacto, siempre** |
| Vencimiento | sí, lo chequea el consumidor | no — la frescura es tu recibo |
| Atado a | el handle | el handle **y la clave del requester** |

Public inputs, en el orden exacto en que los circuitos los declaran (es el orden con el que se
verifica; uno fuera de lugar verifica una afirmación que nadie quiso hacer):

```
attest_base       handle_commit, tier, count, volume_band, penalty_band,
                  expiry, token, decimals, rep_root, verified
reveal_advanced   handle_commit, fields_mask, out_count, out_volume, out_penalty,
                  requester, token, rep_root
```

`handle_commit` es el seudónimo de mercado, y es **rotable a propósito**: otro salt es otro handle,
y el viejo muere sin vínculo. Sin handle no hay consulta — el handle es la capability.

### Registro, crédito y el flag (2026-10-01)

Una cuenta puede existir **sin Passport** (una cuenta *abierta*). Por eso la hoja lleva dos cuentas
distintas de lo que pasó, y el listado muestra cada una donde corresponde:

- **El registro** — todo deal completado y su volumen, con o sin Passport, con la misma contraparte o
  con otra. Es lo que el listado muestra como `count` y `volume_band`, y lo que el perfil revela
  exacto. Dice **qué pasó**.
- **El crédito** — los deals que compran tier: una vez por contraparte, dentro de la ventana, y sólo
  si **las dos** cuentas eran verificadas cuando el deal se activó. Es de donde sale el `tier`. Dice
  **cuánto vale**.
- **`verified`** — el flag exacto de la hoja: 1 si hay una prueba de humanidad detrás, 0 si la cuenta
  es abierta. No es una cota: la hoja lo compromete y la prueba no puede decir otra cosa.

Una cuenta abierta opera, suma registro y paga sus castigos como cualquiera, pero **nunca acredita
ni la acreditan**, así que su tier es T1 por construcción (la lib rechaza un listado abierto por
encima de T1). Tampoco puede trabar bond. Si después se verifica, conserva todo lo que tiene —
registro y castigos incluidos — y desde ahí sus deals con verificadas acreditan.

---

## 3. Tres pisos y un techo

La regla que hace que el listado valga la pena leerlo:

| Campo | Dirección honesta | Por qué |
| --- | --- | --- |
| `tier` | **piso** — se puede subestimar | una afirmación verdadera más débil sigue siendo verdadera |
| `count` | **piso** | ídem |
| `volume_band` | **piso** | ídem |
| `penalty_band` | **techo** — se puede exagerar | subestimar un castigo no es más débil: es falso |

Todo lo bueno sólo se puede subestimar. Todo lo malo sólo se puede exagerar. Las dos direcciones se
llaman igual: honestas. En el circuito son literalmente dos comparaciones opuestas
(`attest_base/src/main.nr`), y hay un test que las ancla juntas para que la asimetría no se pierda
en un refactor: `the_listing_shows_floors_and_one_ceiling`.

Que el castigo sea **obligatorio** es la decisión menos obvia y la más importante. El tier ya netea
el castigo dentro del score, así que una cuenta T2 sancionada cae a T1 y se vuelve indistinguible de
una recién llegada — justo la distinción que más necesita una contraparte. El band la restituye sin
publicar el contador.

---

## 4. Los escalones

**Volumen** — los cortes son *lotes*, no números redondos de un token favorito. Un lote es
`UNIT = 250 × 10^decimals`, la misma unidad con la que el score compra tier, así que el escalón se
lee igual en cualquier token y a cualquier escala.

| Band | Lotes | En tokens enteros |
| --- | --- | --- |
| 0 | menos de 1 | *todavía no completó un lote* |
| 1 | 1–3 | 250+ |
| 2 | 4–19 | 1.000+ |
| 3 | 20–79 | 5.000+ |
| 4 | 80–399 | 20.000+ |
| 5 | 400+ | 100.000+ |

El cupo de T5 es **sin límite sólo con bond**: sin él la escalera topea en 5.000.

**Castigo** — los cortes son *eventos*: un stalemate del tribunal o una disputa abandonada suma 5, un
deadlock (una disputa sin tribunal que nadie resolvió) suma 10 a cada parte, una derrota en tribunal
suma 15 (§E.3.14.7).

| Band | Puntos | Qué significa |
| --- | --- | --- |
| 0 | 0 | nunca pasó nada |
| 1 | 1–5 | un stalemate o una disputa abandonada |
| 2 | 6–15 | varios de esos, un deadlock, o una derrota probada en tribunal |
| 3 | 16+ | más de una derrota |

Un band y no la cifra porque **un número crudo en una pantalla pública es una huella digital**:
"47 deals, 12.350 de volumen" identifica más de lo que informa. Quien quiera el número exacto pide
el perfil, y ahí el dueño decide.

**Qué mide cada número.** El `count` del listado es el **registro**: cuántos deals completó, todos
(desde 2026-10-01). El **crédito** que alimenta el tier es otra cosa: desde 2026-09-23 un deal suma
ahí **una vez por contraparte** — el primero con cada cuenta cuenta, los siguientes con la misma no — y
desde 2026-10-01 sólo entre dos cuentas verificadas. Los castigos no se deduplican nunca. Así que el
tier no mide actividad sino **cuánta gente distinta, con un humano detrás, operó con él**: un cliente
habitual deja de sumarle después del primer trato, y una camarilla cerrada satura en su propio tamaño
en vez de comprar la escalera con fees. El registro, en cambio, sí se puede inflar repitiendo deals
(pagando los fees de cada uno): informa, pero **la señal de confianza es el tier**.

El **tier** y su cupo salen de la misma tabla (§E.3.14.7):
`score = satSub(count + volumen/UNIT, castigo)` — sobre el **crédito**, no sobre el registro —, con umbrales 10 / 25 / 50 / 100 y cupos de
250 / 500 / 1.000 / 2.000 / 5.000 tokens (400 / 700 / 1.500 / 5.000 / sin límite con bond). El cupo
acota `inFlight + principal`: es **exposición concurrente**, no tamaño máximo de un deal. Y el que
ata es **el más chico de los dos lados**, así que una posición grande necesita una contraparte que
también se la haya ganado.

### El bond, y por qué levanta el cupo

| Tier | Cap base | Cap con bond |
| --- | ---: | ---: |
| T1 | 250 | 400 |
| T2 | 500 | 700 |
| T3 | 1.000 | 1.500 |
| T4 | 2.000 | 5.000 |
| T5 | 5.000 | sin límite |

Es un mecanismo, no un premio. El cap mide cuánto acepta el protocolo dejar expuesto por lo que
alguien **demostró**, y un historial informa pero no responde por nada. El bond sí: es capital propio
trabado, en riesgo del mismo veredicto que castigaría a su dueño. Se pierde exactamente cuando un
tribunal falla en contra —el 70% del lock del perdedor va al ganador y el 30% al panel que decidió—
o cuando su dueño deja una disputa sin tribunal en deadlock —va al sink, no a nadie—. Si las partes
arreglan con la corte ya abierta, o el tribunal rehúsa, cada una deja el 15% de su propio lock al
panel (2026-10-05). Vuelve entero en todo lo demás: cierre pacífico, arreglo antes de escalar,
disputa abandonada, deal ZK.

Un deal con el panel oficial lleva siempre bond de los dos lados (2026-10-05): el panel cobra de ahí.
Para una persona, eso exige una cuenta verificada.

El ratio es 10% del principal, **por deal y acumulativo**: la suma de locks cubre el 10% de todo lo
que tengas en vuelo, así que el cupo con bond no se recicla entre posiciones abiertas.

**Dos cosas que un frontend tiene que tener claras.** El bond sube el techo de *quien lo puso*, no el
del deal: el cap que ata sigue siendo el más chico de los dos lados, así que un T4 con bond frente a
un T1 sin bond hace un deal de 250. Y **tener bond no se puede exhibir de antemano** — el vault
privado rechaza las lecturas de saldo (un agregado por sujeto linkearía todos los deals de ese
sujeto), y ningún attestation prueba capacidad de bond. La columna "con bond" del listado es
*potencial*, no un hecho probado. Lo único que demuestra que el lock existe es la activación: si el
deal se activó con BONDS, el lock está. Mostrar "tiene bond" antes de eso es afirmar algo que nadie
probó — la quinta trampa de la lista de abajo.

### El perfil de un pool (2026-10-05)

Un pool es una cuenta más, con las mismas reglas, sólo que **pública**: es un negocio y su historial lo
quieren ver sus LPs y sus contrapartes. Todo se lee del contrato, sin pruebas, por pool y por token:

| Lectura | Qué es |
| --- | --- |
| `poolStats` | El **registro**: deals completados, volumen, y el castigo (+5, +10, +15 como cualquiera) |
| `poolCredit` | El **crédito**: deals que cuentan para el tier, uno por Provider distinto, a lo sumo 16 por día |
| `poolScore` | `satSub(crédito + volumen acreditado/UNIT, castigo)`, la misma fórmula |
| `poolCap(…, conBond)` | El cupo del tier, con o sin la columna bond |
| `poolInFlight` | Lo que tiene abierto ahora contra ese cupo |
| `poolBondOf` / `poolFreeOf` | Su bond en el vault, total y libre. Es público, a diferencia del de una persona |

Tres cosas que un frontend tiene que mostrar bien:

1. **Un pool nuevo es T1**, tenga el capital que tenga: 250 tokens abiertos a la vez (400 con bond).
   Su capital no compra tier. Lo compran Providers distintos que operaron con él.
2. **El crédito es una vez por Provider.** El aval del Controller publica un `cpTag = H(S_provider,
   pool)` y el pool suma sólo la primera vez que ve cada uno. Ese tag liga entre sí los deals de un
   mismo Provider con ese pool —no con otros pools—, y es el precio de que la regla del par se pueda
   chequear en claro.
3. **El que actúa es un operador verificado, pero la reputación es del pool.** Cada Controller registró
   un tag de operador en el pool y avala cada deal con una cuenta verificada. Su wallet queda pública
   como operador de ese pool; su cuenta no. Los castigos van al pool, no al Controller.

El Provider de enfrente sigue sumando como siempre: una vez por cada Controller distinto que lo avaló.

---

## 5. Qué no se puede falsificar

Todo esto lo prueba el circuito. No hay que confiar en ningún servidor, ni en el nuestro:

- **La cuenta existe y es una sola.** La hoja tiene que ser miembro del árbol bajo `rep_root`, y el
  handle deriva del mismo secreto que la hoja. Un handle sin cuenta atrás no tiene prueba.
- **El tier sale de los stats propios, computado adentro.** No es un número que alguien declare: el
  score se calcula en el circuito desde count/volumen/castigo **con el castigo ya restado**.
- **Los stats son por token.** Una prueba de USDC no puede montarse sobre una hoja de otro token.
- **La escala no se elige.** `decimals` es público justamente porque `UNIT = 250 × 10^decimals`: con
  una escala privada, polvo compraría el band de volumen más alto (hay un test que lo ancla — el
  mismo número crudo es band 1 a 6 decimales y band 0 a 18).
- **El perfil es exacto, no una cota.** `out = mask × campo`: el valor propio de la hoja o cero.
- **El castigo no tiene interruptor.** `out_penalty == penalty`, incondicional, aunque el perfil
  esconda todo lo demás. Un perfil puede publicarse bajo el handle sin listado detrás; si el castigo
  fuera opcional acá, el band del listado tendría una puerta trasera.
- **Una prueba no se reusa.** Cada public input es parte de la afirmación: editar uno rompe la
  verificación. Está pineado empíricamente con tamper tests contra el `bb` real — tier exagerado,
  requester re-apuntado, band subestimado, castigo puesto en cero.

---

## 6. Qué tenés que chequear vos

El circuito no tiene reloj, no lee la chain y no sabe qué token es cuál. Cuatro chequeos quedan del
lado del consumidor, y los cuatro fallan cerrado:

| Chequeo | Por qué no puede hacerlo el circuito |
| --- | --- |
| `expiry` contra tu reloj | una prueba no sabe qué hora es |
| `rep_root` vivo (`isKnownRoot`) | la prueba afirma sobre *una* raíz; si sigue viva lo dice el contrato |
| `decimals` contra el ERC-20 servido | el circuito sólo ve un número, no el contrato |
| la prueba misma, con el `bb` pineado | es el verificador |

La lib de referencia los hace todos y devuelve **errores nombrados, no un booleano**:

```ts
import {
  ATTEST_BASE_PUBS, splitAttestation, verifyAttestationBase,
  type AttestBasePubs,
} from "./circuits/js/lib/verify.ts";

const { proof, pubs } = splitAttestation(blob, ATTEST_BASE_PUBS.length);
const named = Object.fromEntries(
  ATTEST_BASE_PUBS.map((n, i) => [n, pubs[i]]),
) as AttestBasePubs;

const r = await verifyAttestationBase({ proof, pubs: named, vk }, {
  now: BigInt(Math.floor(Date.now() / 1000)),
  decimalsOf: async (token) => BigInt(await erc20(token).read.decimals()),
  rootAlive: (root) => accountTree.read.isKnownRoot([toBytes32(root)]),
});

if (!r.ok) return rechazar(r.errors);   // ["attestation expired: ...", "rep_root not live: ..."]
mostrar(r.checks);                       // ["proof verified", "volume 1000 tokens+ moved", ...]
```

Omitir `decimalsOf` o `rootAlive` no rompe: la lib los saltea y **lo dice en `checks`**, para que
nadie crea que chequeó algo que no chequeó. `now` es la excepción: sin reloj se niega a verificar.

### Quién te la muestra (2026-10-02)

Los cuatro chequeos dicen que la attestation es verdadera. Ninguno dice que sea de quien te la muestra:
`attest_base` no tiene un input público que la ate a quien la presenta, y los listados son públicos, así
que cualquiera puede copiar la de otro en un engagement y tu verificación la da por buena.

Antes de operar con alguien, pedile un `reveal_advanced` con `requester` = una clave tuya de esa
conversación (en la plataforma, tu chat key: `PLATAFORMA.md` ENG-11). Sólo el dueño de `sk_id` puede
producirlo, y atado a tu clave no le sirve a nadie más. Chequeá dos cosas: que nombre la misma
`handleCommit` que la attestation, y que su `requester` sea tu clave.

Puede venir con la máscara en cero, pero el castigo va crudo siempre: probar que el handle es suyo te
muestra su castigo exacto, no sólo la banda. Es el precio, y se acepta (Anexo R, 2026-10-02): lo ve sólo
quien está por operar con él, y la banda ya era pública. Frente a un pool no hace falta: sus estadísticas, su tier y
su cupo están atados a su address, que es el Holder del deal, y se leen del contrato.

---

## 7. Siete trampas al mostrarlo

Las siete son fáciles de cometer, y cada una afirma de alguien algo que la prueba no dice:

1. **Un campo oculto llega en cero.** Cuando el bit de la máscara está apagado, `out_volume` vale 0
   *por construcción*. Mostrarlo como "0 de volumen" es acusar a alguien de no haber operado nunca.
   Tiene que decir **no revelado**.
2. **Band 0 de volumen no es "cero".** Significa *menos de un lote*. Una cuenta nueva no es una
   cuenta que no movió nada.
3. **Los pisos no son cifras.** `count` y `volume_band` son cotas inferiores: mostralos con `≥`, o
   estás publicando como hecho algo que la prueba no dice.
4. **El cupo es concurrente.** El tier acota `inFlight + principal`, no el tamaño de un deal: "hasta
   1.000 USDC en juego a la vez", no "por deal".
5. **La columna con bond es potencial.** Nadie prueba tener bond antes de activar, y el vault privado
   no deja leerlo. Mostralo como lo que es — el cupo al que esa cuenta *podría* llegar si traba el
   10% — nunca como un sello de que ya lo hizo.
6. **El registro no es confianza.** `count` y `volume_band` cuentan todo deal completado, también los
   repetidos y los de cuentas sin Passport. Ordenar o premiar por ahí es premiar actividad que nadie
   avaló. La señal es el **tier** (y el band de castigo); el registro es contexto. Y una cuenta con
   `verified = 0` se marca como tal — "sin Passport" — al lado del handle, nunca escondida.
7. **Una attestation no dice quién te la muestra.** Es pública: cualquiera la copia de un listado y la
   pega en un engagement, y verifica bien. Hasta que la contraparte te dé el perfil atado a tu clave
   (§6, *Quién te la muestra*), la reputación que ves es la del handle, no necesariamente la de quien te
   habla: marcala "handle sin probar".

### Cómo armar el listado

Para elegir rápido a la mejor contraparte, cada fila muestra el handle, el sello **verificada / sin
Passport**, el tier con su cupo, el band de castigo, y el registro (`≥ N deals`, `250+ movidos`).
Un orden razonable:

1. **Castigo**, de menor a mayor — lo único que se puede exagerar y nunca esconder.
2. **Tier**, de mayor a menor — se gana una vez por contraparte verificada distinta: es lo caro de
   falsificar.
3. **Verificada** antes que sin Passport, a igual tier.
4. **Registro** (volumen, después deals) como desempate.

Quien quiera más pide el **perfil**: el dueño decide si lo entrega, y si lo ata a la clave de quien
lo pidió. Ahí el registro viene exacto si lo elige, y el castigo exacto siempre.

---

## 8. Series entregadas

Un historial acá es **una secuencia que su dueño arma y entrega**, no algo que exista del lado de
nadie más. El árbol es la cadena: sus raíces son los bloques, y cada attestation es una foto de una
raíz — sin fecha propia. La fecha es tu recibo.

`circuits/js/lib/chain.ts` certifica lo entregado:

- una sola `handleCommit` en toda la serie (si no, son dos cuentas pegadas);
- los contadores crudos nunca bajan — `count` del listado y `out_count` del perfil son **el mismo
  contador** (el registro), y el castigo y el escalón de volumen tampoco bajan;
- el flag nunca vuelve atrás: una cuenta abierta puede pasar a verificada, una verificada nunca pasa a
  abierta (2026-10-01);
- el band de castigo de un listado no puede quedar **por debajo** de un castigo exacto que la misma
  serie ya reveló (al revés sí: exagerar es verdadero y sólo le cuesta al autor).

Y dos cosas que deliberadamente **no** hace:

- **No chequea el tier.** El tier baja cuando hay castigo, y una cadena honesta muestra exactamente
  eso. Exigirlo monótono rechazaría el caso honesto que el diseño quiere visible.
- **No pone precio a los huecos.** Cuánto vale un silencio de tres meses es tu política. El protocolo
  no codifica sospecha por ausencia.

---

## 9. Qué se ve y qué no

**No se ve:** quién es la persona, con qué wallet opera, cuáles deals de la chain son suyos, si el
handle tuvo otro nombre antes, cuánto tiene en bonds. Lo único que vincula un handle con una cuenta
es la prueba, y la emite su dueña.

**Sí se ve** (y se acepta, §E.3.15.8): montos, timings y eventos de cada deal; los fees; el
`dealSubject` de cada deal; los depósitos al vault con su wallet.

**El costo de esta capa, dicho:** cada campo público angosta el conjunto de anonimato. `count` y
`volume_band` juntos insinúan el ticket promedio. Y hay un caso que conviene tener presente: como el
castigo va crudo en el perfil y es un número poco común, **rotar el handle protege bien a una cuenta
limpia y peor a una sancionada** — dos perfiles del mismo dueño con el mismo castigo exacto
correlacionan. Es el precio directo de que el castigo no sea ocultable, y nos parece el correcto.

---

## 10. Lo que todavía no está

- **Un attestation ata `repRoot` pero no ata deployment.** Si vas a leer esta reputación desde otra
  dapp, chequeá la raíz contra el árbol canónico: contra un clon del contrato, una prueba
  perfectamente válida afirma sobre otro árbol. Hoy no hay identificador de deployment en los public
  inputs; agregarlo es un campo más y está anotado como pendiente.
- **La verificación corre el binario `bb` pineado.** Para un listado en browser falta el camino
  bb.js/WASM.
- **Nada de esto está desplegado con usuarios todavía.**

---

## 11. Dónde está cada cosa

```
circuits/crates/attest_base/        el listado: los tres pisos y el techo
circuits/crates/reveal_advanced/    el perfil: la máscara y el castigo crudo
circuits/crates/pluri_commitments/  tiers.nr — la tabla §E.3.14.7 y los dos bands
circuits/js/lib/verify.ts           consumer side: bb + los cuatro chequeos
circuits/js/lib/chain.ts            series entregadas
circuits/js/lib/tiers.ts            el twin JS de la tabla (volumeBand, penaltyBand, tierOf)
circuits/js/lib/account.ts          recuperar una cuenta desde el secreto y la chain
test/fixtures/proofs/ + vks/        pruebas y VKs comprometidas: no hace falta el toolchain para leer
```

```sh
cd circuits && nargo test --workspace   # 103 tests: cortes, cotas, cuentas abiertas y los negativos que importan
bun test circuits/js                    # 96: semántica del consumer, con bb real cuando está
```

El toolchain de Noir/Barretenberg está pineado por sha256 en [`circuits/README.md`](./circuits/README.md).
CI no lo necesita: las pruebas viajan comprometidas.
