# Reto Salud Digna — Flujo, estados, eventos y endpoints (propuesta)

> **Estado: propuesta para revisar con Saul.** Nada de esto está construido ni
> decidido. Sale del documento del reto de Salud Digna (Hackatec, categoría
> Software Inteligente) y de la referencia de la API facial v2 del equipo. Lo marcado como **[supuesto]** hay que
> confirmarlo antes de construir.

## 0. Idea en una línea

Un **motor de contexto** (identidad + trámite + eventos) en el centro, y cada canal
(Web, WhatsApp, llamada con Retell, App, Clínica) como un **adaptador** delgado que
solo traduce: lee el contexto del paciente, emite eventos y nunca guarda estado
propio. No es un buzón unificado: el paciente no "continúa la conversación", continúa
**el trámite**.

```
 Web ──────────┐                          ┌──► Tablero en tiempo real (asesor / admin)
 WhatsApp ─────┤                          │
 Retell (voz) ─┼─► Motor de contexto ─────┼──► Línea de tiempo unificada
 App ──────────┤   (identidad, trámite,   │
 Clínica ──────┘    eventos, auditoría)   └──► Avisos salientes (WhatsApp, push)
                          │
                          │ servicio externo, opcional y con consentimiento
                          ▼
                   API facial v2 (Cloud Run)
```

**Propiedad intelectual:** por la cesión de derechos a Salud Digna, la API facial
v2 se **consume como servicio externo por HTTP**; su código no entra al repo del
reto. Lo mismo con cualquier código previo del equipo: antes de copiarlo, se le
pregunta a Saul.

---

## 1. El recorrido a demostrar (caso de Ana, adaptado)

El PDF pide Web → WhatsApp → Call Center → App. Nuestro recorrido agrega el cierre
físico en la clínica, que es donde el reconocimiento facial (opcional) aporta.

| # | Canal | Qué hace Ana | Qué hace el sistema | Estado del trámite al salir | Eventos clave |
|---|---|---|---|---|---|
| 1 | **Web** | Elige "Ultrasonido obstétrico", ve el precio, elige la clínica Centro y un horario. Da su celular para "guardar su avance". Cierra la pestaña antes de confirmar. | Crea sesión anónima, luego un **paciente provisional** con su teléfono. Aparta el horario 24 h. Manda OTP por SMS/WhatsApp **[supuesto: OTP por WhatsApp]**. | `horario_apartado` | `sesion.iniciada`, `estudio.cotizado`, `clinica.elegida`, `horario.apartado`, `identidad.telefono_declarado` |
| 2 | **WhatsApp** | Horas después escribe "hola". | El número coincide con el paciente; WhatsApp ya prueba que controla ese número → identidad `verificada`. El bot responde: *"Hola Ana, tienes un ultrasonido apartado en Centro el sábado 10:00. ¿Lo confirmo?"*. Ana pregunta por la preparación y responde "sí, pero tengo una duda del pago". | `pendiente_confirmacion` (pasos completos salvo la duda) | `canal.entrada`, `identidad.verificada`, `contexto.recuperado`, `mensaje.recibido`, `preparacion.enviada`, `pendiente.registrado` |
| 3 | **Llamada (Retell)** | Llama al número del call center. | Retell consulta el contexto por el número que llama **antes de contestar**. El agente de voz saluda por nombre, ve la duda pendiente ("pago"), la resuelve, confirma la cita y si Ana pide hablar con una persona, le avisa que un asesor la contactará a ese mismo número y crea una devolución de llamada. El asesor (rol Asesor) ve todo en el tablero. | `confirmado` | `llamada.iniciada`, `contexto.recuperado`, `pendiente.resuelto`, `cita.confirmada`, `llamada.terminada`, `llamada.resumida` |
| 4 | **App** | Abre la app e inicia sesión con su teléfono (OTP). | Ve su cita confirmada, la preparación y un **QR de check-in**. Opcional: acepta el consentimiento facial y registra su rostro. | `confirmado` | `sesion.iniciada`, `cita.consultada`, `consentimiento.facial_otorgado`, `rostro.registrado` |
| 5 | **Clínica** | Llega a recepción. | Check-in con **QR** o con **rostro** (si dio consentimiento). Recepción ve la ficha sin preguntar nada. Ana pasa a sala. | `en_clinica` → `atendido` | `checkin.realizado`, `atencion.iniciada`, `atencion.terminada` |

### 1.1 Variaciones para la resiliencia (fase 3 del reto)

El jurado evalúa interrupciones, información parcial y recuperación. Cada una se
demuestra con el mismo motor:

| Situación | Qué pasa | Cómo se recupera |
|---|---|---|
| Ana cierra la web sin dar teléfono | Queda una sesión anónima con cookie | Si vuelve en el mismo navegador, se retoma. Si da el teléfono después, la sesión **se fusiona** con su paciente (`identidad.fusionada`) |
| Escribe por WhatsApp desde **otro número** | No hay coincidencia | El bot pide nombre + fecha de nacimiento + OTP al número registrado; al validar, se **vincula** el nuevo número (`identidad.canal_vinculado`) |
| La llamada se corta a la mitad | Retell manda `call_ended` | Lo que se avanzó ya son eventos guardados; el pendiente queda abierto y el siguiente canal lo ofrece |
| El apartado del horario vence | Tarea programada | `horario.liberado`, estado `expirado`; al volver, el sistema ofrece horarios nuevos con el mismo estudio y clínica (no empieza de cero) |
| Dos canales a la vez (WhatsApp y llamada) | Escrituras concurrentes | El trámite tiene `version`; las transiciones usan concurrencia optimista (`409 version_conflicto`) y el adaptador relee el contexto |
| Webhook repetido (WhatsApp y Retell reintentan) | Mismo evento dos veces | `clave_idempotencia` = id del mensaje / de la llamada; el segundo se ignora |
| Sin datos de salud en el LLM | — | El texto se **anonimiza** antes de mandarlo al modelo (nombre, teléfono, CURP → marcadores) |

---

## 2. Identidad

### 2.1 Niveles

| Nivel | Cómo se llega | Qué permite |
|---|---|---|
| `anonimo` | Sesión web sin datos | Cotizar, elegir clínica |
| `declarado` | Dio un teléfono o correo sin probarlo | Apartar horario; **no** ver datos de otros trámites |
| `verificado` | OTP correcto, o mensaje desde ese número de WhatsApp, o llamada desde el número registrado **[supuesto: el caller ID basta para leer el contexto, no para cambiar datos sensibles]** | Ver y continuar sus trámites, confirmar citas |
| `verificado_fuerte` | Rostro con consentimiento (API facial v2) o identificación en recepción | Check-in sin QR, recoger resultados |

### 2.2 Estrategia de resolución

1. **Llave principal:** teléfono en formato E.164 (`+52…`). Es lo que comparten Web
   (lo pide), WhatsApp (viene en el webhook) y la llamada (caller ID).
2. **Llaves secundarias:** correo, `paciente_id` de la App, `sujeto_id` del rostro.
3. Cada canal guarda en el paciente un **identificador de canal**
   (`{canal, valor, verificado, fecha}`); la resolución busca por ese par.
4. **Fusión:** una sesión anónima o un paciente provisional se fusiona con uno
   verificado cuando el OTP coincide. La fusión es un evento y se puede auditar.
5. **Nunca** se cruza con la base de personas desaparecidas de KAXTEN.

---

## 3. Estados del trámite

Un **trámite** = una solicitud de estudio (o paquete) para un paciente. Un paciente
puede tener varios.

```
borrador ─► cotizado ─► clinica_elegida ─► horario_apartado ─► pendiente_confirmacion ─► confirmado ─► en_clinica ─► en_atencion ─► atendido ─► resultados_listos
                │              │                   │                     │                  │
                └──────────────┴───────────────────┴─────────► cancelado ◄────────────────────┘
                                                    │
                                                    └─► expirado (venció el apartado) ─► horario_apartado (al retomar)
                                         confirmado ─► no_asistio (pasó la hora sin check-in)
```

| Estado | Significa | Lo dejan entrar | Sale con |
|---|---|---|---|
| `borrador` | Hay intención, aún sin estudio | Cualquier canal | `estudio.cotizado` |
| `cotizado` | Estudio y precio vistos | Web, WhatsApp, Retell, App | `clinica.elegida` |
| `clinica_elegida` | Clínica elegida | Igual | `horario.apartado` |
| `horario_apartado` | Horario retenido N horas | Igual | `cita.confirmada`, `horario.liberado` |
| `pendiente_confirmacion` | Todo listo, falta un "sí" o hay un pendiente abierto | Igual | `cita.confirmada` |
| `confirmado` | Cita confirmada | Igual + Clínica | `checkin.realizado`, `cita.cancelada`, `cita.no_asistio` |
| `en_clinica` | Hizo check-in | Clínica | `atencion.iniciada` |
| `en_atencion` | En el estudio | Clínica | `atencion.terminada` |
| `atendido` | Estudio hecho | Sistema | `resultados.listos` |
| `resultados_listos` | Final feliz | — | — |
| `cancelado`, `expirado`, `no_asistio` | Finales o recuperables | — | `expirado` y `no_asistio` se pueden **reactivar** sin perder estudio ni clínica |

Además del estado, el trámite guarda:

- `pasos`: lista de pasos con `completado` y en qué canal (`estudio`, `clinica`,
  `horario`, `datos_paciente`, `preparacion_leida`, `confirmacion`).
- `pendientes`: dudas o datos faltantes abiertos (`{id, tipo, texto, canal_origen, abierto}`).
- `canal_actual` y `canales_visitados`.
- `version` (entero, para concurrencia optimista).

El estado **se calcula a partir de los eventos** (y se guarda como proyección para
leerlo rápido). Así la línea de tiempo y el estado nunca se contradicen.

---

## 4. Catálogo de eventos

### 4.1 Sobre común

```json
{
  "id": "evt_01J…",
  "tipo": "cita.confirmada",
  "version_esquema": 1,
  "ocurrio_en": "2026-11-21T15:02:11Z",
  "canal": "retell",
  "actor": { "tipo": "agente_voz", "id": "agente_retell_1" },
  "paciente_id": "pac_…",
  "tramite_id": "tra_…",
  "correlacion_id": "call_…",
  "clave_idempotencia": "retell:call_…:confirmar",
  "datos": { "cita_id": "cit_…" }
}
```

- `canal`: `web`, `whatsapp`, `retell`, `app`, `clinica`, `asesor`, `sistema`.
- `actor.tipo`: `paciente`, `asesor`, `agente_voz`, `bot`, `recepcion`, `sistema`.
- Los eventos son **inmutables**; una corrección es otro evento.
- `datos` no lleva datos de salud en texto libre: solo ids y valores de catálogo.

### 4.2 Eventos

| Grupo | Tipo | Emite | Cambia estado | Datos principales |
|---|---|---|---|---|
| Sesión | `sesion.iniciada` | todos | — | `dispositivo`, `nivel_identidad` |
| | `sesion.cerrada` / `sesion.abandonada` | web, app | — | `ultimo_paso` |
| | `canal.entrada` | todos | `canal_actual` | `canal_anterior` |
| Identidad | `identidad.telefono_declarado` | web, app | — | `telefono_enmascarado` |
| | `identidad.otp_enviado` / `identidad.otp_fallido` | sistema | — | `medio` |
| | `identidad.verificada` | sistema | nivel → `verificado` | `metodo` (otp, whatsapp, caller_id) |
| | `identidad.canal_vinculado` | sistema | — | `canal`, `valor_enmascarado` |
| | `identidad.fusionada` | sistema | — | `origen_id`, `destino_id` |
| | `identidad.verificada_facial` | clínica, app | nivel → `verificado_fuerte` | `similitud` |
| Consentimiento | `consentimiento.aviso_aceptado` | web, app | — | `version_aviso` |
| | `consentimiento.facial_otorgado` / `consentimiento.facial_revocado` | app, clínica | — | `version_texto` |
| | `rostro.registrado` / `rostro.borrado` | sistema | — | `vectores` (cuántos) |
| Trámite | `tramite.creado` | todos | `borrador` | `motivo` |
| | `estudio.cotizado` | web, wa, retell, app | `cotizado` | `estudio_id`, `precio` |
| | `clinica.elegida` | igual | `clinica_elegida` | `clinica_id` |
| | `horario.apartado` | igual | `horario_apartado` | `horario_id`, `vence_en` |
| | `horario.liberado` | sistema | `expirado` | `razon` |
| | `datos.capturados` | igual | paso `datos_paciente` | `campos` (solo nombres) |
| | `preparacion.enviada` / `preparacion.leida` | wa, app | paso | `estudio_id` |
| | `pendiente.registrado` / `pendiente.resuelto` | todos | `pendiente_confirmacion` | `pendiente_id`, `tipo` |
| | `cita.confirmada` | igual | `confirmado` | `cita_id` |
| | `cita.reprogramada` | igual | `confirmado` | `horario_anterior`, `horario_nuevo` |
| | `cita.cancelada` | igual | `cancelado` | `razon` |
| | `cita.no_asistio` | sistema | `no_asistio` | — |
| | `tramite.reactivado` | todos | estado previo | `desde` |
| Conversación | `mensaje.recibido` / `mensaje.enviado` | whatsapp, web (chat) | — | `mensaje_id`, `intencion` (clasificada), **sin texto** en el evento; el texto va en la colección de mensajes con su retención |
| | `intencion.detectada` | sistema (NLP) | — | `intencion`, `confianza` |
| Llamada | `llamada.iniciada` | retell | — | `call_id` |
| | `llamada.transferida` | retell | — | `a` (asesor) |
| | `llamada.terminada` | retell | — | `duracion_s`, `razon_fin` |
| | `llamada.resumida` | retell | — | `resumen` (anonimizado), `sentimiento` |
| Escalamiento | `escalamiento.creado` | bot, agente_voz, paciente | — | `escalamiento_id`, `modalidad` (en_vivo, devolucion_llamada), `motivo`, `prioridad` |
| | `escalamiento.notificado` | sistema | — | `medios` (sms, correo) |
| | `escalamiento.asignado` / `escalamiento.resuelto` / `escalamiento.vencido` | asesor, sistema | — | `asesor_id`, `resolucion` |
| | `devolucion.intento` | asesor | — | `resultado` (contesto, no_contesto, buzon) |
| Asesor | `asesor.tomo_caso` / `asesor.nota_agregada` | asesor | — | `asesor_id` |
| | `contexto.recuperado` | todos | — | `canal`, `pasos_completos` (para medir continuidad) |
| Clínica | `checkin.realizado` | clínica | `en_clinica` | `metodo` (qr, facial, manual), `clinica_id` |
| | `checkin.rechazado` | clínica | — | `razon` (sin_cita, otra_clinica, facial_dudoso) |
| | `atencion.iniciada` / `atencion.terminada` | clínica | `en_atencion` / `atendido` | `sala` |
| | `resultados.listos` | sistema | `resultados_listos` | — |

**[supuesto]** Transporte: los eventos se guardan en una colección/tabla append-only
y se publican a los suscriptores (tablero) por **Server-Sent Events**. Si después
hace falta, se pasa a Pub/Sub sin cambiar el catálogo.

---

## 5. Endpoints del backend

### 5.1 Leyenda de la columna "API facial v2"

- **Cubre**: la v2 ya lo hace; el motor de contexto solo la llama (o la llama el
  teléfono directo).
- **Parcial**: la v2 hace la parte biométrica; falta la parte del reto (consentimiento,
  evento, paciente).
- **Nuevo**: no existe; hay que construirlo en el motor de contexto.

Todo endpoint nuevo usa `Authorization: Bearer <token>` con rol
(`paciente`, `asesor`, `admin`, `recepcion`, `canal` para los adaptadores) salvo los
webhooks, que se validan con la firma de cada proveedor. Errores con la misma forma
que la v2: `{"error": "<código>", "mensaje": "<texto>"}`.

### 5.2 Lo que ya da la API facial v2

| Endpoint v2 | Uso en el reto |
|---|---|
| `GET /v2/salud`, `GET /v2/modelo` | Sonda de la demo |
| `POST /v2/indices/{indice}/sujetos/{sujeto_id}/vectores` | Alta del rostro desde la App (el teléfono calcula el vector; no se sube foto) |
| `POST /v2/indices/{indice}/sujetos/{sujeto_id}/rostros` | Alta del rostro con foto desde recepción |
| `DELETE /v2/indices/{indice}/sujetos/{sujeto_id}` | Revocar consentimiento (derecho de cancelación) |
| `POST /v2/indices/{indice}/busqueda/vector` y `/busqueda/foto` | Check-in facial en clínica |
| `POST /v2/vectores` | Foto → vector sin guardar (si el kiosco no calcula vectores) |

Cómo encaja **sin tocar el código de la v2**:

- Índice nuevo `pacientes` **[supuesto]**; `sujeto_id` = `paciente_id`; `grupo` =
  `clinica_id` para que el check-in compare solo contra pacientes con cita en esa
  clínica (más rápido y menos falsos positivos).
- Necesita una **llave de cliente nueva** en `V2_LLAVES` con `indices: ["pacientes"]`
  (es configuración del servidor, no código; la hace Saul).
- Pedir siempre `con_datos=false`: los datos del paciente viven en el motor de
  contexto, no en la v2.
- Umbral recomendado para check-in: **0.7** o más, y si la similitud queda entre el
  umbral y ~0.8 se pide QR (no se confía solo en el rostro).
- **Pendiente de revisar:** hoy la v2 guarda en una base compartida con otro
  proyecto del equipo. Para el reto conviene un proyecto o base aparte; eso sí podría
  requerir un despliegue nuevo de la v2 con otro `V2_BASE_DATOS`.

### 5.3 Endpoints

Prefijo `/api/v1` del motor de contexto.

#### Identidad y sesión

| Método y ruta | Qué hace | Quién | API facial v2 |
|---|---|---|---|
| `POST /identidad/sesiones` | Crea sesión anónima (web) y devuelve token de sesión | web | Nuevo |
| `POST /identidad/otp` | Envía OTP al teléfono (`{telefono, canal_envio}`) | web, app | Nuevo |
| `POST /identidad/otp/verificar` | Verifica OTP, crea o resuelve el paciente, **fusiona** la sesión anónima, devuelve JWT de paciente | web, app | Nuevo |
| `POST /identidad/resolver` | Resuelve un identificador de canal (`{canal, valor}`) → `paciente_id` y nivel. Lo usan los adaptadores | canal | Nuevo |
| `POST /identidad/vincular` | Vincula un canal nuevo (otro número) tras verificar | canal, asesor | Nuevo |
| `POST /identidad/facial/verificar` | Recibe vector o foto + `clinica_id`, llama a la v2 en el índice `pacientes`, grupo `clinica_id`, y emite `identidad.verificada_facial` | recepción | **Parcial** (la búsqueda la hace la v2) |

#### Pacientes y consentimiento

| Método y ruta | Qué hace | Quién | API facial v2 |
|---|---|---|---|
| `GET /pacientes/me` | Perfil del paciente autenticado | paciente | Nuevo |
| `GET /pacientes/{id}` | Ficha (datos enmascarados según rol) | asesor, admin, recepción | Nuevo |
| `PATCH /pacientes/{id}` | Actualiza datos (emite `datos.capturados`) | paciente, asesor | Nuevo |
| `POST /pacientes/{id}/consentimientos` | Registra aviso de privacidad o consentimiento facial con la versión del texto | paciente | Nuevo |
| `POST /pacientes/{id}/rostro` | Con consentimiento vigente: reenvía vectores/fotos a la v2 (`sujeto_id = paciente_id`) y emite `rostro.registrado` | paciente (app), recepción | **Parcial** (alta en la v2) |
| `DELETE /pacientes/{id}/rostro` | Revoca: borra en la v2 y emite `consentimiento.facial_revocado` + `rostro.borrado` | paciente | **Parcial** (baja en la v2) |

#### Contexto (el corazón)

| Método y ruta | Qué hace | Quién | API facial v2 |
|---|---|---|---|
| `GET /pacientes/{id}/contexto` | **Una sola respuesta** con todo lo que un canal necesita para continuar: trámite activo, estado, pasos, pendientes, último canal, siguiente acción sugerida y resumen corto (anonimizado para LLM si `?para=llm`) | canal, asesor | Nuevo |
| `GET /contexto?canal=whatsapp&valor=+52…` | Igual pero resolviendo la identidad en la misma llamada (lo que usan WhatsApp y Retell) | canal | Nuevo |

#### Trámites

| Método y ruta | Qué hace | Quién | API facial v2 |
|---|---|---|---|
| `POST /tramites` | Crea trámite (`borrador`) | todos | Nuevo |
| `GET /tramites/{id}` | Estado, pasos, pendientes, `version` | dueño, asesor, admin | Nuevo |
| `GET /pacientes/{id}/tramites` | Lista por paciente (activos primero) | dueño, asesor | Nuevo |
| `POST /tramites/{id}/acciones` | **Única puerta para cambiar el estado.** Cuerpo `{accion, datos, version, clave_idempotencia}`; `accion` ∈ `cotizar`, `elegir_clinica`, `apartar_horario`, `capturar_datos`, `registrar_pendiente`, `resolver_pendiente`, `confirmar`, `reprogramar`, `cancelar`, `reactivar`. Valida la transición, emite el evento y devuelve el trámite nuevo. `409 version_conflicto` / `409 transicion_invalida` | todos | Nuevo |
| `POST /tramites/{id}/checkin` | Check-in (`{metodo: qr|facial|manual, clinica_id, token_qr?}`); valida cita del día y clínica | recepción | Nuevo (el facial usa `/identidad/facial/verificar`) |
| `GET /tramites/{id}/qr` | Token de check-in firmado y de corta duración | paciente | Nuevo |

#### Catálogo (datos de ejemplo, marcados como tales)

| Método y ruta | Qué hace | Quién | API facial v2 |
|---|---|---|---|
| `GET /catalogo/estudios` | Estudios con precio y preparación | público | Nuevo |
| `GET /catalogo/clinicas?cerca=lat,lng` | Clínicas | público | Nuevo |
| `GET /catalogo/clinicas/{id}/horarios?estudio_id=&fecha=` | Horarios libres | público | Nuevo |

#### Eventos y línea de tiempo

| Método y ruta | Qué hace | Quién | API facial v2 |
|---|---|---|---|
| `POST /eventos` | Ingesta genérica para un adaptador (eventos que no cambian estado: `mensaje.*`, `sesion.*`, `canal.entrada`) | canal | Nuevo |
| `GET /pacientes/{id}/linea-tiempo` | Línea de tiempo unificada, paginada, filtrable por canal | dueño, asesor, admin | Nuevo |
| `GET /tramites/{id}/eventos` | Eventos de un trámite | asesor, admin | Nuevo |
| `GET /stream/eventos` | **SSE**: eventos en tiempo real (filtros `paciente_id`, `clinica_id`) para el tablero | asesor, admin | Nuevo |

#### Adaptadores de canal

| Método y ruta | Qué hace | Quién | API facial v2 |
|---|---|---|---|
| `GET /canales/whatsapp/webhook` | Verificación del webhook de WhatsApp Cloud API (`hub.challenge`) | Meta | Nuevo |
| `POST /canales/whatsapp/webhook` | Mensaje entrante: valida firma, resuelve identidad por `from`, lee contexto, clasifica intención, responde y emite eventos. Idempotente por id de mensaje | Meta | Nuevo |
| `POST /canales/whatsapp/enviar` | Mensaje saliente (recordatorio, preparación) con plantilla aprobada | sistema, asesor | Nuevo |
| `POST /canales/retell/entrante` | Webhook de llamada entrante: con el número que llama devuelve **variables dinámicas** para el agente (nombre, estudio, clínica, horario, pendientes) **[supuesto: verificar el formato exacto en la doc de Retell]** | Retell | Nuevo |
| `POST /canales/retell/funciones/{nombre}` | Funciones que el agente de voz llama a mitad de la llamada: `obtener_contexto`, `buscar_horarios`, `confirmar_cita`, `reprogramar_cita`, `registrar_pendiente`, `escalar_a_humano` (no transfiere en vivo: crea una devolución de llamada al mismo número). Cada una traduce a `/tramites/{id}/acciones` | Retell | Nuevo |
| `POST /canales/retell/eventos` | Eventos de la llamada (`call_started`, `call_ended`, `call_analyzed`) → `llamada.*`; guarda resumen anonimizado | Retell | Nuevo |
| `POST /canales/web/eventos` | Atajo de `/eventos` para el sitio (abandono de página, paso visto) | web | Nuevo |

La **App** no necesita adaptador propio: usa los endpoints de paciente con su JWT.
La **Clínica** usa `checkin` y `facial/verificar` con rol `recepcion`.

#### Asesor y administración

| Método y ruta | Qué hace | Quién | API facial v2 |
|---|---|---|---|
| `GET /asesor/bandeja` | Pacientes con pendientes abiertos o llamadas transferidas | asesor | Nuevo |
| `POST /escalamientos` | Crea un escalamiento. En web y WhatsApp es `en_vivo`; en una llamada es `devolucion_llamada` con el mismo número. Encola los avisos por SMS y correo | canal, Retell (función `escalar_a_humano`) | Nuevo |
| `GET /escalamientos?estado=&modalidad=` | Casos abiertos para el asesor | asesor | Nuevo |
| `POST /escalamientos/{id}/tomar` | El asesor toma el caso (y la conversación pasa a `con_asesor`) | asesor | Nuevo |
| `POST /escalamientos/{id}/intentos` | Registra un intento de devolución de llamada | asesor | Nuevo |
| `POST /escalamientos/{id}/resolver` | Cierra el caso y devuelve la conversación al bot | asesor | Nuevo |
| `POST /conversaciones/{id}/mensajes` | El asesor contesta por el mismo canal (WhatsApp o web) | asesor | Nuevo |
| `GET/PUT /asesor/preferencias-notificacion` | Qué avisos recibe por SMS y correo | asesor | Nuevo |
| `POST /tramites/{id}/notas` | Nota interna del asesor (emite `asesor.nota_agregada`) | asesor | Nuevo |
| `GET /admin/journey` | Embudo por estado y por canal, en vivo | admin | Nuevo |
| `GET /admin/metricas` | Tiempo por etapa, % de transiciones con contexto recuperado, abandonos recuperados | admin | Nuevo |
| `GET /admin/auditoria` | Quién leyó o cambió datos de qué paciente | admin | Nuevo |
| `POST /admin/demo/reiniciar` | Deja los datos de la demo en su estado inicial (para que el jurado opere sin miedo) | admin | Nuevo |

### 5.4 Resumen de cobertura

| | Cuántos |
|---|---|
| Endpoints de la v2 que se reusan tal cual | 6 (salud, modelo, alta por vector, alta por foto, baja, búsqueda) |
| Endpoints nuevos que envuelven a la v2 (Parcial) | 3 (`/identidad/facial/verificar`, `POST` y `DELETE /pacientes/{id}/rostro`) |
| Endpoints nuevos sin relación con la v2 | El resto (~35): identidad, contexto, trámites, eventos, canales, tablero |

La v2 resuelve **solo el factor biométrico opcional**. Los cuatro pilares del reto
(identidad, contexto, trazabilidad, seguridad) son trabajo nuevo.

---

El modelo de datos que respalda estos endpoints está en [`MODELO_DE_DATOS.md`](MODELO_DE_DATOS.md).

## 6. Seguridad y privacidad (lo mínimo para la demo)

- JWT con rol y expiración corta; los adaptadores usan su propio token de servicio.
- Webhooks: firma de Meta (`X-Hub-Signature-256`) y la de Retell.
- Datos enmascarados según rol (el asesor ve `+52 ••• ••• 1234`).
- El rostro solo con consentimiento explícito y revocable; la v2 no guarda fotos de
  socios y aquí se pide `con_datos=false`.
- Texto anonimizado antes del LLM; se prefiere Vertex AI.
- Auditoría de lecturas de ficha (no solo de escrituras).
- Credenciales de prueba por rol en el `README.md` del repo del reto (lo pide el
  entregable 6.2), nunca llaves reales.

---

## 7. Decisiones abiertas para Saul

1. **Dónde vive el motor de contexto:** propuesta FastAPI en Cloud Run (el equipo ya
   tiene CI/CD así) con Firestore en un **proyecto aparte** del de KAXTEN, por la
   cesión de derechos y para no rozar la producción de KAXTEN. Alternativa: Postgres
   si se quiere modelo relacional para el entregable de datos.
2. **App del paciente:** ¿se arma desde KAXTEN Base (hay que preguntarlo por la
   propiedad intelectual) o desde cero?
3. **OTP:** por WhatsApp, por SMS o simulado en la demo.
4. **WhatsApp:** número de prueba de la Cloud API de Meta o canal simulado.
5. **Facial en clínica:** ¿entra en la demo o se deja como extensión? Si entra,
   crear la llave `pacientes` en la v2 y decidir la base de datos.
6. **Sitio Web:** página propia simple o simulación dentro del tablero.
