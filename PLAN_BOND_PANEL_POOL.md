# Plan — el panel se paga con el bond, y el pool es un peer

Decisión: Anexo R de `PROTOCOLO.md`, 2026-10-05. Este archivo es el plan de implementación y su estado;
cuando todo está hecho queda como registro de qué se tocó y en qué orden.

**Estado (2026-10-05): hecho.** 837 tests de forge en verde (7 saltados, los de siempre), `nargo test` y
`bun circuits:test` en verde, `script/e2e.sh` en verde sobre anvil. Lo que no se ejercita: un deal de pool de
punta a punta con pruebas reales (el fixture de `vouch` nombra el pool `0x9001…9001`; los tests de pool usan
verificadores mock).

## Lo que se acordó

1. **Panel ⇒ bonds de los dos lados.** Un deal con el panel oficial lleva bonds en el vault que el panel
   pinea. Una persona necesita una cuenta verificada para trabarlo; un pool lo pone desde su capital.
2. **Sin dispute fee.** El panel no cobra por abrir la corte. Sigue la disponibilidad (0,2% por árbitro).
3. **El 30% del bond del perdedor va a los árbitros** que votaron con el ruling; el 70% al ganador. Si
   nadie votó, ese 30% también va al ganador.
4. **Acuerdo con la corte abierta, o corte que rehúsa:** cada parte deja el 15% de su propio bond a la
   corte, y el panel cobra como si hubiera fallado unánime.
5. **El pool es un peer.** Reputación pública con la misma escalera (§E.3.14.7): score, tier, cap
   concurrente que sube con el bond, ventana de 16 créditos por época, penalidades iguales. Sale la
   excepción "un pool oficial no pasa por el cap".
6. **El bond del pool es público y es del pool.** Lo fondea el pool desde su capital (o cualquiera, como
   aporte); vuelve al pool. Entra en el NAV. Sale `PoolWithBonds`.
7. **Cuenta + operador.** Cada lado es una cuenta (reputación, tier, cap, bond, penalidades) y un operador
   (el humano que actúa). En una persona son lo mismo; en un pool el operador es el Controller. El kernel
   le pasa el operador al passport (`identify(account, operator, …)`), igual que ya distingue Holder y
   Controller.
8. **Todo Controller de un pool está verificado.** Registra en el pool un `operatorTag = H(sk_id, pool)`;
   cada deal del pool lleva el aval (`vouch`) de ESE operador, verificado. El aval es obligatorio.
9. **Regla del par.** El pool suma una vez por Provider distinto (`cpTag = H(S_provider, pool)`, que el
   aval publica); el Provider suma una vez por Controller distinto (como hoy).
10. **Penalidades sólo a la cuenta.** La wallet del Controller queda pública como operador del pool, sin
    revelar su cuenta.

## Pasos (TDD: test rojo → código → verde, paso por paso)

### 1. El panel se paga con el bond
- [x] `ICourt.bondShareBps()` y `PackageId.arbitration(..., bondShareBps)`: otra parte de la política firmada.
- [x] `BondAction.Shared` (agregado al final del enum): acuerdo con la corte abierta y ruling 3.
- [x] `IBondVault.slash(..., feeTo, feeBps)`, `IBondVault.share(a, b, token, dealId, feeTo, feeBps)` y
      `collect(dealId)`: la parte de la corte queda en el vault y la corte la retira (pull).
- [x] Kernel: ruling 1/2 → slash con la parte de la corte; ruling 3, `mutualCancel` y `coSignedRelease`
      desde `ARBITRATION_ACTIVE` → `Shared`. Corte que derivó: parte 0 (fail-open, todo al ganador).
- [x] Vault público (mock) y `PrivateBondVault`: la parte de la corte; el lock privado que vuelve más chico.
- [x] `ArbiterRegistry`: sin dispute fee; `bondShareBps = 3000`; pinea el vault y exige sus bonds en
      `bind`; `settle` espera la disposición del bond, retira la parte y la reparte.
- [x] Circuito `reabsorb`: devuelve `kept ≤ amount` (agente, en paralelo).

### 2. El pool es un peer
- [x] Circuito `vouch`: `poolId`, `operatorTag`, `cpTag` (agente, en paralelo).
- [x] `IPassport.identify(account, operator, dealId, data)`; el kernel pasa `(holder, controller)` y
      `(provider, provider)`.
- [x] `PrivatePassport`: el lado de un pool exige el aval, verificado, del operador registrado.
- [x] `Pool`: `setOperatorTag`, `authorize` exige el tag del Controller; `fundBond` / `withdrawBond`;
      el NAV cuenta el bond.
- [x] `PrivateBondVault`: cuentas públicas de pool (depósito, lock, devolución, slash a favor).
- [x] `PrivateReputation`: tier, cap concurrente con bond, `inFlight`, crédito una vez por `cpTag`,
      ventana por época; sale `PoolWithBonds`.

### 3. Despliegue y scripts
- [x] `DeployPackages`, `DeployPrivate`, scripts del e2e: parámetros nuevos del panel y del vault.

### 4. Documentación
- [x] `PROTOCOLO.md`: entrada en el Anexo R, §4 (costos y escala), §5.5, §5.8, §E.3.14, finales.
- [x] `PANEL_POLICY.md`, `PLATAFORMA.md`, `REPUTACION.md`, `INFORME.md`, `README.md`.
