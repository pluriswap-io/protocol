# Política del panel de árbitros

Versión 1.3 (2026-10-06). La leen los árbitros de `ArbiterRegistry` antes de aceptar un caso y antes de votar. El
cliente se la muestra al árbitro junto con la invitación a un deal. Lo normativo está en
[`PROTOCOLO.md`](./PROTOCOLO.md) §E.3.14.4. Si esta política y la spec se contradicen, gana la spec.

## 1. Qué se decide

Un deal de PluriSwap custodia un monto en tokens (el **principal**) que depositó el **Holder**. A
cambio, el **Provider** tenía que hacerle al Holder un **pago fuera de la chain**: una transferencia,
Pix, efectivo o el medio que hayan acordado. El Provider marcó el pago como enviado, el
Holder lo disputó y abrió la corte.

Hay una sola pregunta: **¿quién se queda con el principal?**

- **Holder** (voto 1): el pago no se hizo como se acordó. El principal vuelve al Holder.
- **Provider** (voto 2): el pago se hizo como se acordó. El principal va al Provider.

No hay una tercera opción, ni reparto, ni montos. El contrato aplica el resultado. Si el panel empata
o nadie vota, gana el Holder.

## 2. Lo que aceptaste al sentarte

Firmaste el nombramiento (`PanelAppointment`) cuando las partes negociaron el deal. La firma incluye
los términos del panel de ese momento: los plazos, lo que se traba y lo que cuesta abstenerse. Desde la
activación, el contrato te traba el 10% del principal de tu bond hasta que el deal termina.

**Los términos de tu caso no cambian.** La DAO puede cambiar los términos y los pagos del panel (la
disponibilidad y la parte del bond) para los deals que vienen, dentro de topes fijos en el contrato y
con 30 días de aviso (`PROTOCOLO.md` §3.9). Un caso usa siempre los términos con los que se ligó, y el
contrato le paga al panel lo que se fijó al activar el deal. Si no estás de acuerdo con un cambio, pedí la salida el día que
se propone: la salida más larga es de 21 días, así que salís antes de que aplique. La DAO no te puede
elegir, sacar ni vetar, y no puede tocar tu bond. Los números de esta política son los términos de hoy.

Un deal con panel lleva siempre las garantías (bonds) de las dos partes: cada una traba el 10% del
principal. Una persona sólo puede trabarlo con una cuenta verificada, y un pool lo traba con su
propio capital. Tu pago por decidir sale de esas garantías, no de quien abre la corte. Abrir la corte
no le cuesta nada a nadie: no hay fee de disputa.

- **Tenés 4 días para responder**, desde que se abre la corte. Votás en dos pasos para que nadie vea
  tu voto antes de tiempo. Primero lo comprometés, dentro de los primeros 3 días: hasta que el panel
  entero comprometió, lo podés cambiar. Después lo revelás: apenas comprometieron todos, o desde el día
  3, y siempre antes del día 4. Si revelaron todos, el caso se decide en ese momento.
- **Vencidos los 4 días, el que no reveló se abstuvo.** Cualquiera puede cerrar el caso en ese momento.
  Un voto comprometido y no revelado cuenta como abstención.
- **Abstenerse cuesta.** Si no revelás un voto y otro árbitro sí votó, perdés la mitad de lo trabado.
  Si no vota nadie del panel, cada uno pierde todo lo trabado. Lo que pierdas va al lado que perdió
  sin que lo escucharan.
- **Votar distinto que la mayoría no cuesta bond**, pero no cobrás la parte del bond del que perdió,
  y tus estadísticas públicas (`statsOf`) muestran cuántas veces votaste con el resultado.
- **Qué cobrás.**
  - **Disponibilidad:** el 0,2% del principal, si el deal cerró sin disputa o si votaste.
  - **Por decidir:** el 30% de la garantía del que perdió (el 3% del principal). Se reparte entre los
    que votaron con el resultado. El otro 70% va al que ganó. Cobrás lo mismo gane quien gane.
  - **Si las partes arreglan con la corte abierta,** cada una deja el 15% de su propia garantía, y
    cobran los tres como si el fallo hubiera sido unánime.
  - **Si nadie vota,** ese 30% va al que ganó: nadie lo ganó decidiendo.
  - **Cuándo cobrás:** la parte del bond llega al registro cuando el contrato liquida las garantías del
    deal. Hasta entonces `settle` espera (`BondsPending`).
- **Conflicto.** El contrato ya impide que te sientes en un deal donde sos parte, comparado a nivel de
  persona. Si tenés otro conflicto que el contrato no puede ver (conocés a una parte, operás con ella),
  no firmes el nombramiento. Una vez sentado, retirarte es abstenerte.

## 3. Cómo llega la evidencia

La evidencia no pasa por ningún contrato ni por ningún servidor que la pueda leer. Cuando se abre la
corte, una parte te manda **sellada con tu clave** (`encryptionKeyOf`) la clave de la conversación del
deal. Con esa clave abrís la conversación completa.

- **Cada mensaje está firmado** por la chat key de su autor y nombra el último mensaje que su autor vio.
  La wallet de esa parte del deal (el Holder, el Provider o el Controller de los `terms` on-chain) firmó
  una vez la delegación de esa key para esta conversación (`ChatKey`). El cliente verifica cada delegación
  contra la chain y cada mensaje contra su key, y te marca cualquiera que no cierre. Un mensaje sin firma
  válida, o firmado por una key que nadie de los `terms` delegó, no es de una parte.
- **Para preguntar, escribí en la conversación.** Tu cliente te pide una vez que tu wallet de árbitro
  delegue una chat key para el caso. Desde ahí tus mensajes quedan en el mismo grafo que los de las partes,
  y las dos los ven.
- **La cadena muestra los huecos.** Si una parte te comparte la conversación recortada, el primer
  mensaje de la otra parte que nombre uno que falta lo deja a la vista. Las dos partes pueden
  compartirte la conversación, y te conviene leer las dos versiones.
- **Todo lo que te muestran lo vio también la otra parte.** Un documento entra como adjunto de un
  mensaje de la conversación, nunca por un canal aparte. Así la contraparte lo pudo contestar.
- **El pago acordado se puede verificar.** Si el deal firmó un `fiatCommit`, una parte te puede
  revelar la apertura: rail, moneda, monto, cuenta destino y salt. El cliente la compara con el commit
  on-chain. Si coinciden, ese es el pago que las dos partes firmaron, y ya no se discute. Sólo queda
  saber si el pago ocurrió.

Una captura, un extracto o un comprobante adjunto sigue siendo la palabra de quien lo subió: la firma
prueba quién lo mandó, no que sea verdadero. Pesalo con eso en mente.

## 4. Estándar de decisión

Decidí por **balance de probabilidades**: qué versión es más probable con la evidencia que tenés.

La **carga es del Provider**. Tiene que mostrar que el pago llegó al Holder como se acordó: el
destinatario, el monto, la moneda y el medio correctos, dentro del plazo del deal. La evidencia típica
es un comprobante con destinatario, monto, fecha y referencia, o un extracto.

El Holder muestra que el pago no llegó, llegó de menos, se revirtió o fue a otro destinatario. Sirven
el extracto del período, un aviso de contracargo o reversión, o mensajes que muestren que los datos
acordados no son los del pago.

**Si la evidencia no alcanza para ninguna versión, el Provider no cumplió su carga: votá Holder.** No
te abstengas por eso. Abstenerte no es neutral: te cuesta el bond y, si nadie vota, gana el Holder
igual.

## 5. Guía

- **Importan el monto y el destinatario, no el formato.** Un pago con el destinatario y el monto
  correctos, pero con otra referencia en el texto libre, es un pago hecho.
- **Tarde no es lo mismo que nunca.** Si el pago llegó después del plazo pero antes de la disputa y el
  Holder se lo quedó, favorecé al Provider. Si el Holder lo devolvió o lo rechazó, favorecé al Holder.
- **Reversiones.** Un pago que después se revirtió, tuvo un contracargo o se reclamó no es un pago
  hecho. Favorecé al Holder, salvo que la reversión la haya causado el Holder. La cripto, una vez
  asignada, es final. El fiat no lo es nunca, y ese riesgo es de las partes.
- **Pagos parciales.** Un pago incompleto no es un pago hecho. Favorecé al Holder. Después de una
  disputa no hay reparto: las partes podían arreglar entre ellas antes de abrir la corte.
- **Otro destinatario.** Un pago a datos distintos de los que dio el Holder no es un pago hecho, salvo
  que esos datos los haya dado el Holder. Si hay `fiatCommit`, los datos del Holder son los del commit.
- **Silencio.** Una parte que no muestra evidencia no cumplió su parte. Si es el Provider, gana el
  Holder.
- **Promesas por fuera.** Un acuerdo aparte que cambia los términos (otro monto, otra moneda) sólo
  cuenta si en la conversación firmada se ve que lo aceptaron las dos partes.

## 6. Qué pasa después del fallo

Cuando revelaron todos, o cuando vencen los 4 días, el contrato lee la mayoría de los votos revelados
y cualquiera puede cerrar el deal. El principal va a quien ganó. La garantía del que perdió va al que
ganó, menos el 30% que queda para el panel. La reputación de cada uno registra el resultado: la
privada de una persona, o la pública de un pool.
Nada de eso te pide otra acción. Tu pago queda como crédito en el registro y lo retirás con `settle` y
`withdrawCredit`.

## 7. Confidencialidad

La conversación tiene datos personales: nombres, cuentas, montos, a veces documentos de identidad. Las
partes te la mostraron a vos y a nadie más.

- No la compartas, no la copies fuera del cliente y no la guardes cuando el caso termina.
- No la uses para nada que no sea este voto.
- No contactes a las partes por fuera. Si necesitás algo, pedilo en la conversación, donde lo ven las
  dos.

La privacidad de un deal de PluriSwap se rompe sólo en la disputa, y sólo ante vos. Que la exposición
termine en vos es parte de lo que aceptaste al sentarte.
