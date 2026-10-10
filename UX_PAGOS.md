# Experiencia de pago — aspiracional

Cómo debería sentirse un deal con `PAYMENT_PROOF` para las dos personas que lo usan, y qué tiene que
hacer un cliente para lograrlo sin perder ninguna de las garantías del protocolo.

**Estado: aspiracional.** Nada de esto está construido: la UI salió del repo el 2026-09-23, y todavía
no hay un rail real validado. Los ejemplos usan un rail genérico cuya evidencia es un mail firmado con DKIM. Este archivo fija hacia dónde apuntar, no cómo es. Lo normativo —lo que un cliente
**tiene** que hacer para ser conforme— vive en [`PROTOCOLO.md`](./PROTOCOLO.md) §E.3.12.1 (*Obligación del
cliente*) y §E.3.13 (legibilidad de `fiatCommit`); si algo de acá contradice la spec, gana la spec.

Está afuera de `PROTOCOLO.md` por la misma razón que [`REPUTACION.md`](./REPUTACION.md): su lector no diseña
el protocolo, construye un cliente.

---

## La idea en una línea

**Nadie ve nunca una clave, un hash ni un commitment.** Cada persona ve su deal —cuánto, a quién, por
dónde— y el cliente hace por detrás todo lo que la criptografía exige. Cuando el cliente no puede
verificar algo, no le pide a la persona que confíe: se lo dice y no la deja firmar.

## Principios

1. **Lenguaje de negocio, siempre.** *"Vas a recibir $U 1.500,00 por transferencia en la cuenta \*\*\*\*1234"*, no
   *"firmá `DealTerms` con `fiatCommit = 0x…`"*. Lo que la persona aprueba es el preimage, en claro.
2. **Lo que el cliente no verificó, no se firma.** No existe el botón *"aprobar de todos modos"*. Un
   momento de firma que se puede saltear es un momento de firma que se puede phishear.
3. **Las firmas viajan dentro de flujos que ya existen.** Aprobar la clave del rail no es un paso nuevo:
   va con la firma del deal, o con una notificación del propio deal.
4. **La iniciativa es del cliente propio, nunca de la contraparte.** Ninguna firma de este flujo se pide
   por un link, un chat o un mensaje de la otra parte.
5. **Cada estado dice qué hacer ahora.** Nunca *"pendiente"* a secas: *"esperando que X haga Y; si no
   pasa antes de Z, pasa W"*.

---

## Holder — el que recibe el fiat

### Al firmar el deal

Una sola pantalla:

> **Vas a entregar 40 USDC y recibir $U 1.500,00**
> por transferencia, en tu cuenta \*\*\*\*1234, de parte de *handle_del_provider*.
>
> Si el pago no se prueba antes de las 18:40 de hoy, los 40 USDC vuelven a tu wallet.
>
> [ Confirmar ]

Lo que pasa por detrás, en este orden:

1. El cliente arma `fiatCommit` a partir de lo que la persona ve (rail, moneda, monto, su cuenta, un salt
   nuevo), lo recomputa y confirma que es el que está en los términos (§E.3.13).
2. Consulta la clave vigente con la que el rail firma sus avisos —en DKIM, el registro DNS del
   selector, en más de un resolver, cruzado con el archivo histórico de claves— y la compara con las
   claves por defecto del adapter (`anchors()`) y con su `sunset()`.
3. Si la clave vigente está cubierta y la ventana del deal cabe antes del `sunset()`: firma sólo
   `HolderAuthorization`.
4. Si no: firma también `KeyApproval(dealId, keyHash)`. El `dealId` se precomputa (§E.3.13), así que las dos
   firmas salen juntas, antes de la activación.
5. Si no pudo verificar la clave: **no hay botón.** *"No pudimos confirmar la firma de mails de tu banco.
   Probá en unos minutos; si sigue, este deal no se puede ofrecer por este canal."*

**Dos firmas, un toque.** Con una wallet inteligente, las dos firmas van en un lote y la persona ve una
sola confirmación. Con una EOA son dos popups; el segundo tiene que explicarse solo: *"Autorizá la firma
actual de tu banco para comprobar este pago"*.

### Si el rail rota su clave a mitad de deal

Notificación del propio deal, nunca un mensaje de la contraparte:

> **Tu banco actualizó su firma de mails.**
> La verificamos contra su servidor. Confirmá para que el pago de $U 1.500,00 de este deal pueda
> acreditarse.
>
> [ Confirmar ]

Si el cliente no pudo verificar la clave nueva:

> **Detectamos un cambio en la firma de tu banco que no pudimos verificar.**
> No firmes nada que te pidan por otro canal. Si el pago no se prueba antes de las 18:40, los 40 USDC
> vuelven a tu wallet.

### Regla de comunicación, fija

> **PluriSwap nunca te va a pedir por chat, mail o mensaje que apruebes nada.**
> Todo lo que tengas que confirmar aparece en tu deal.

---

## Provider — el que paga el fiat

### Antes de pagar: el semáforo

El paso de pagar muestra si el comprobante que va a recibir se va a poder probar:

| Estado | Qué ve | Qué puede hacer |
| --- | --- | --- |
| **Verde** | *"Listo. Transferí $U 1.500,00 desde el saldo de tu cuenta a \*\*\*\*1234. Tu comprobante va a poder probarse."* | Pagar |
| **Ámbar** | *"El banco cambió su firma. Esperando que el Holder la confirme."* | Esperar; el botón de pagar está bloqueado |
| **Rojo** | *"Este canal no está disponible ahora. No pagues."* | Nada; el deal va a vencer y los USDC vuelven al Holder |

Ámbar y rojo bloquean el pago a propósito: el riesgo declarado de `PAYMENT_PROOF` es exactamente el
Provider que pagó y no puede probarlo (§E.3.12.1), y la única defensa buena es no pagar en ese estado.

### Después de pagar: probar

> **Encontramos el aviso del banco de las 14:32 por $U 1.500,00 a \*\*\*\*1234.**
> [ Probar este pago ]
>
> Generando la prueba… (unos segundos; tu mail no sale de este dispositivo)
>
> **Listo.** Los 40 USDC están en tu wallet.

Y el reloj, siempre visible: *"Probá antes de las 18:40. Después de esa hora, cualquiera puede cancelar el
deal y ya no vas a poder cobrarlo."* (§E.3.12.1, proof tardío: vale mientras nadie haya cancelado).

---

## Estados de un deal ZK, como los ve cada uno

| Estado on-chain | Holder | Provider |
| --- | --- | --- |
| `FUNDED`, antes del deadline | *"Esperando el pago de $U 1.500,00"* | Semáforo + *"Pagá antes de las 18:40"* |
| `FUNDED`, pasado el deadline | *"El pago no llegó a tiempo. Podés cancelar y recuperar tus USDC"* | *"Venció el plazo. Si ya pagaste, probá ahora: todavía vale hasta que alguien cancele"* |
| `RELEASED` | *"Pago recibido. Entregaste 40 USDC"* | *"Cobraste 40 USDC"* |
| `CANCELLED` | *"Deal cancelado. Tus 40 USDC volvieron"* | *"Deal cancelado"* (+ si pagó y no probó: cómo reclamar el fiat por fuera del protocolo) |

---

## Lo que falta para que esto exista

- **Un rail elegido.** Decide qué evidencia existe, cómo se importa y cuánto tarda en probarse.
- **Generar el proof en el dispositivo** (bb.js/WASM, LHF-8). Sin esto no hay *"tu comprobante no sale de
  este dispositivo"*.
- **Cómo entra el comprobante** (ver abajo): la extensión del navegador como camino principal.
- **Firma en lote.** Decide si el Holder ve una confirmación o dos.
- **Verificación de claves en el cliente.** Resolución DNS en varios resolvers y el archivo histórico de
  claves, sin depender de un servidor de Labs para decidir.

## Cómo entra el comprobante

La evidencia de un rail DKIM es el mail original, byte por byte: cualquier cambio —reenviarlo, editarlo,
copiar y pegar el texto— rompe la firma. Y el mail tiene datos personales que no pueden salir del
dispositivo. Con esas dos restricciones:

1. **Extensión del navegador — el camino principal en desktop.** Lee el mail original desde la sesión de
   webmail que la persona ya tiene abierta (en Gmail, lo mismo que "Mostrar original"), busca el aviso del
   rail que corresponde al deal —remitente, monto, hora posterior a la activación—, genera la prueba ahí
   mismo y la envía. Sin OAuth, sin servidor, sin que la persona sepa qué es un `.eml`. El costo: depende
   de la interfaz de cada webmail, que cambia sin aviso, y hay que mantener una integración por proveedor
   (Gmail primero).
2. **OAuth en el navegador — el camino en el celular, donde no hay extensiones.** Permiso de sólo lectura,
   con el token guardado únicamente en el cliente. El costo: en Gmail ese permiso es un *restricted scope*,
   que exige una verificación de seguridad de Google para la app, y la pantalla de permiso asusta
   (*"leer tus mails"*) aunque el cliente sólo busque uno.
3. **Subir el `.eml` a mano — el respaldo universal.** Cualquier proveedor de mail, cualquier dispositivo,
   para quien no quiere instalar nada.

**Descartado: reenviar a una dirección de importación.** Reenviar rompe la firma DKIM, y una dirección de
importación es un servidor que recibe los mails de pago de los usuarios: contacto con la pata fiat (principio 9)
y el fin de *"tu mail no sale de este dispositivo"*.

La extensión puede además hacer el resto del flujo del Provider (§ *Después de pagar*) y, del lado del
Holder, la verificación de la clave del rail contra el DNS antes de firmar (§ *Al firmar el deal*).

## Preguntas abiertas

- ¿Cuánto tiempo de prueba tolera una persona en un teléfono antes de abandonar?
- ¿Qué pasa con el Provider que pagó en ámbar o en rojo a pesar del bloqueo? El protocolo no lo puede
  ayudar; el cliente sí puede explicarle cómo reclamar el fiat por fuera.
- ¿Cómo se ve el rescate cuando el Holder no responde? Hoy el Provider sólo puede esperar el timeout.
