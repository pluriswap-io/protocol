# Simulaciones del ecosistema

¿El protocolo premia lo que dice premiar? Los tests prueban que cada transición hace lo que dice y el
e2e camina cada camino una vez; ninguno de los dos puede decir si el **sistema** —mucha gente, parte
honesta y parte no, eligiendo contrapartes por lo que el protocolo le muestra— hace que la honestidad
convenga. Este informe responde eso, con números medidos contra los contratos reales.

Está afuera de `PROTOCOLO.md` como `REPUTACION.md`: es evidencia, no spec. Las decisiones que salieron de acá
viven en la Anexo R de [`PROTOCOLO.md`](./PROTOCOLO.md) (2026-09-24).

---

## Resumen

1. **Con tribunal, la honestidad es lo que gana en el largo plazo.** En la dinámica evolutiva, un mercado
   con tribunal converge a la honestidad en todas las semillas. Sin tribunal, cae en un equilibrio malo
   la mayoría de las veces.
2. **Sin tribunal no hay regla del kernel que lo arregle.** Probamos tres —el forfeit, el stalemate 50/50 y
   la destrucción mutua (quemar el principal)—. La mejor, la destrucción mutua, funciona contra tramposos
   racionales y falla contra tramposos tercos frente a víctimas que ceden. La literatura explica por qué:
   sin información verificable no existe un mecanismo compatible con incentivos para un he-said-she-said.
3. **El tribunal tiene que ser bueno, y la apuesta proporcional a su error.** Con el bond del 10% de hoy,
   un tribunal que acierta el 90% ya está al borde: la honestidad domina pero no siempre se impone, y al
   80% o menos el mercado se degrada. Es exactamente la cota de Schwartzbach (2020).
4. **El diseño a construir** es una disputa con tribunal en la que la apuesta (el bond) se dimensiona según
   el error del tribunal, el perdedor paga el arbitraje —también cuando cede después de abrir la corte—,
   la reputación castiga sólo al perdedor, y los deals sin tribunal quedan acotados a montos chicos.

---

## Cómo se simula

Tres herramientas en `script/sim/`, todas contra el stack desplegado en Anvil (el mismo que despliega el
e2e). Todo es on-chain salvo la pata fiat, que es un libro contable: el protocolo nunca ve fiat, y su
simulación tampoco. 1 token = 1 unidad de fiat.

| Herramienta | Qué pregunta | Cómo se corre |
| --- | --- | --- |
| `ecosystem.ts` | ¿Puede un tramposo ganar, con estrategias fijas? | `script/sim/run.sh [puerto]` |
| `longrun.ts` | ¿Hacia dónde va la población si cada uno puede cambiar de estrategia? | `script/sim/run.sh [puerto] --longrun` |
| `tribunal.ts` | ¿A partir de qué tasa de error del tribunal se rompe la honestidad? | `script/sim/run.sh [puerto] --tribunal` |

**Actores.** Holders que venden stablecoins por fiat y Providers que los compran. Estrategias: honesto
(paga cuando dice que pagó, libera cuando le pagaron), mentiroso (un Provider que marca el fiat sin pagar)
y extorsionador (un Holder que cobra y después disputa). Frente al deadlock, cada lado tiene una actitud:
el tramposo **racional** cede cuando le conviene, el **terco** nunca; la víctima **firme** nunca le entrega
nada a un tramposo, la que **cede** compara pérdidas y entrega si le sale más barato.

**Mercado.** Cada Holder busca un Provider que ambos acepten; se rechaza a quien tiene penalty band ≥ 2. El
deal se hace por el cap más chico de los dos (tope 5.000). Un excluido puede comprar una identidad nueva
por 25 USDC. El reloj de Anvil avanza por cada deadline.

**Largo plazo (evolutivo).** Cada generación son varias rondas de comercio real; al final, cada agente mira
a otro de su rol y, si ganó más, copia su estrategia con probabilidad proporcional a la diferencia
(dinámica de imitación, la forma práctica de la dinámica del replicador), con un 3% de mutación. Un
intercambio que se completa de verdad le da un 2% de excedente a cada lado: por eso comercia la gente, y
sin él "no comerciar" empataría con "comerciar honesto".

Todo es determinista por semilla (`SEED`); cada resultado se corrió con tres.

---

## 1. El stalemate 50/50 premiaba el fraude

Resultado neto promedio por agente (USDC, fiat incluido), 12 rondas, tres semillas. Kernel con stalemate
50/50 en el timeout de una disputa sin tribunal.

| | Core puro | Sin tribunal, víctima firma el split | Sin tribunal, víctima va al deadlock | Con tribunal |
| --- | ---: | ---: | ---: | ---: |
| Holder honesto | −375 | −803 | −244 | **+54** |
| Holder extorsionador | +750 | **+1.424** | −832 | **−61** |
| Provider honesto | −375 | −803 | −240 | **−1** |
| Provider mentiroso | +1.500 | **+3.275** | +1.605 | **−382** |

- **El split lavaba reputación.** La víctima firmaba 50/50 antes que ir al deadlock, el split contaba como
  cierre pacífico, y el tramposo sumaba crédito, subía de tier y estafaba montos cada vez más grandes. Con
  paquetes el fraude pagaba **más** que en Core puro.
- **El castigo simétrico caía sobre los honestos.** Con víctimas firmes, el +10 a ambos excluía a las
  víctimas del mercado mientras el tramposo compraba otra identidad.

## 2. La destrucción mutua: bien contra el racional, mal contra el terco

Kernel actual: después de una disputa no hay split (sólo cancel o co-signed release), y el deadlock sin
tribunal quema el principal.

| | Core, terco vs firme | Sin tribunal, tramposo racional | Sin tribunal, terco vs firme | Sin tribunal, terco vs víctima que cede | Con tribunal |
| --- | ---: | ---: | ---: | ---: | ---: |
| Holder honesto | −722 | **−14** | −444 | −1.628 | **+54** |
| Holder extorsionador | −833 | **−60** | −1.615 | **+2.217** | **−75** |
| Provider honesto | −722 | **−1** | −440 | −1.178 | **−1** |
| Provider mentiroso | 0 | **0** | −390 | **+6.099** | **−386** |

- **Contra el tramposo racional funciona como se diseñó**: disputado, el mentiroso firma la cancelación y el
  extorsionador el release; nadie gana engañando y los honestos sólo pagan fees.
- **Contra el terco hay un agujero.** Frente a un tramposo que no cede, la víctima compara: entregar le
  cuesta el principal; el deadlock, el principal más su bond más +10. Entrega. El terco gana más que con
  el split, y con reputación limpia (un co-signed release después de una disputa cuenta como pacífico).

## 3. El largo plazo: sólo el tribunal converge

Honestos al final de 15 generaciones × 4 rondas (8 por rol), dinámica de imitación.

| Mercado | Semilla 1 | Semilla 2 | Semilla 3 |
| --- | --- | --- | --- |
| Core puro | 1 H / 1 P | 1 H / 1 P | 7 H / 0 P |
| Oficial sin tribunal | **0 / 0** (colapso) | 8 / 8 | 8 H que ceden / **8 P tercos** |
| Oficial con tribunal | **8 / 8** | **8 / 8** | **7 / 8** |

Sin tribunal aparecen los tres equilibrios que predice la teoría: todos honestos (frágil), **colapso
total** (nadie comercia de verdad y un honesto mutante no puede entrar) y **víctimas que ceden explotadas
por tercos**. El mecanismo del último: ceder paga más que la firmeza a nivel individual, así que la
imitación propaga el ceder, y eso vuelve rentable ser terco. La firmeza es un bien público que nadie
provee. Con tribunal los tramposos se extinguen en 6 a 11 generaciones y un mutante tardío no prospera.

## 4. El tribunal imperfecto: la cota de Schwartzbach, medida

El bond ya funciona como la apuesta de Schwartzbach (el lock del perdedor va al ganador) y el abandono ya
es forfeit. Lo que se mide es a partir de qué tasa de acierto la honestidad deja de imponerse con el bond
de hoy (10%). Court fee 25 USDC. El tramposo ahora apuesta al error: el mentiroso espera que el tribunal
falle a su favor, el extorsionador abre la corte alegando que no le pagaron. El racional apuesta sólo si
le conviene en valor esperado; el terco, siempre. 14 generaciones × 4 rondas, 8 por rol.

Honestos al final (de 16):

| Tribunal acierta | Semilla 1 | Semilla 2 | Semilla 3 | Promedio | Error del tribunal (casos) | Resultado medio de la víctima honesta por caso |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| **100%** | 13/16 | 15/16 | 16/16 | **14.7/16** | 0 de 147 | -3 USDC |
| **90%** | 6/16 | 12/16 | 12/16 | **10.0/16** | 28 de 333 | -22 USDC |
| **80%** | 0/16 | 11/16 | 6/16 | **5.7/16** | 132 de 578 | -87 USDC |
| **70%** | 1/16 | 8/16 | 6/16 | **5.0/16** | 238 de 780 | -130 USDC |

La cota teórica con λ = 10%: γ < λ/(x+λ) ≈ 9%, o sea acertar más de ~91%. Lo medido coincide: a 100% la
población converge; a 90% la honestidad domina pero no siempre se impone; a 80% y menos se degrada.

**Un hallazgo sobre accesibilidad.** Incluso con un tribunal perfecto, la víctima honesta termina perdiendo
en buena parte de los casos: cuando un mentiroso racional ve que va a perder, firma la cancelación después
de que la víctima abrió la corte, y la víctima se come el court fee y los contest fees sin recuperar nada.
Quien cede después de abrirse la corte tendría que pagar el arbitraje.

---

## Lo que dice la literatura

**Sin información verificable no hay equilibrio honesto estricto.** Asgaonkar y Krishnamachari (2019)
prueban que un escrow de doble depósito tiene a la honestidad como único equilibrio perfecto en subjuegos
—pero porque el contrato puede verificar la entrega (un hash). Ellos mismos advierten que sin verificación
el problema es "considerablemente más difícil (si no imposible) sin un tercero de confianza", y citan
BitHalo/BitBay, el doble depósito sin verificación, que es nuestra destrucción mutua. La pata fiat no es
verificable on-chain; con `PAYMENT_PROOF` (fase 2) sí lo sería.
[arXiv:1806.08379](https://arxiv.org/abs/1806.08379)

**Con un árbitro mejor que una moneda, la honestidad es estable.** Schwartzbach (2020): quien disputa apuesta
λ, la otra parte apuesta o pierde por abandono, decide el árbitro. Si el árbitro se equivoca con
probabilidad γ < ½ existe un λ, en x·γ/(1−γ) < λ < x·(1−γ)/γ, con el que la honestidad es el único
equilibrio perfecto en subjuegos **y una estrategia evolutivamente estable**. Con reembolso al ganador la
seguridad es estricta. Un árbitro al azar (γ = ½) sólo da seguridad débil.
[arXiv:2008.10326](https://arxiv.org/abs/2008.10326)

**Con seudónimos baratos, el techo es "pagar el derecho de piso".** Friedman y Resnick (2001): si cambiar de
identidad es barato, ningún equilibrio sostiene mucha más cooperación que aquel en que los recién llegados
reciben peor trato hasta ganarse la reputación; las salidas son una cuota de entrada o seudónimos gratuitos
pero irreemplazables (lo que intenta ser Passport).
[JEMS](https://onlinelibrary.wiley.com/doi/abs/10.1111/j.1430-9134.2001.00173.x)

**La reputación tiene que castigar al culpable, no a los dos.** Leimar y Hammerstein (2001): el *image
scoring* —castigar a un tramposo también te baja la reputación— no es evolutivamente estable; el
*standing* —castigar con justificación no te penaliza— sí. El +10 a ambos del deadlock es image scoring, y
por eso la simulación excluía a las víctimas firmes.
[ResearchGate](https://www.researchgate.net/publication/27281285_Cooperation_through_indirect_reciprocity_Image_scoring_or_standing_strategy)

---

## Qué se decidió y qué sigue

**Decidido (Anexo R, 2026-09-24):** sin split después de una disputa, y el deadlock sin tribunal quema el
principal. Es el mejor camino sin tribunal que encontramos —el tramposo sólo gana contra víctimas que
ceden, no contra todas—, pero es un equilibrio débil y así queda declarado.

**Rediseño propuesto de la disputa con tribunal** (siguiente paso, a validar con `tribunal.ts`):

1. **Bond dimensionado por el error del tribunal**, no fijo en 10%: λ > x·γ/(1−γ). Para un tribunal que
   acierta el 80% hace falta ~25%.
2. **El perdedor paga el arbitraje**, también el que cede después de abrirse la corte (hoy la víctima se
   come el fee cuando el mentiroso cancela a último momento). Así quien no tiene capital sólo adelanta.
3. **Reputación tipo standing:** el castigo fuerte sólo al perdedor según el tribunal; nada después de una
   disputa da crédito.
4. **Deals sin tribunal acotados** a los caps de derecho de piso, declarados como equilibrio débil.
5. **Medir la tasa de error real del tribunal** en disputas de pagos fiat, que es el parámetro del que depende
   todo lo demás.

**Adoptado en parte (Anexo R, 2026-10-05):** el punto 2. Con el panel oficial no hay fee de disputa: el panel
cobra el 30% del lock del que pierde, y si las partes arreglan con la corte abierta cada una deja el 15% del
suyo. El bond sigue fijo en el 10% (punto 1 abierto).

---

## Límites

- Poblaciones chicas (8 por rol): el azar pesa, y por eso cada resultado se corrió con tres semillas.
- El tribunal simulado decide con la tasa de acierto que se le fija y sin costo de tiempo; un panel real
  tarda días y su error en este dominio no está medido.
- El excedente del 2% y el costo de identidad de 25 USDC son supuestos; los dos mueven los umbrales.
- Los tramposos del modelo no se coluden, no sobornan jurados ni aprenden estrategias fuera de las cuatro.
