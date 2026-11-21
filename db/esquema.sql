-- =============================================================================
-- Motor de contexto omnicanal — esquema de base de datos (PostgreSQL 15+)
--
-- Propuesta. La explicación de cada tabla está en docs/reto/MODELO_DE_DATOS.md.
--
-- Principios:
--   * Multiempresa: toda tabla de negocio lleva organizacion_id y tiene
--     Row Level Security (RLS) por organización.
--   * Datos personales cifrados por la aplicación (columnas *_cifrado, bytea);
--     para buscar se usa un "índice ciego" (HMAC del valor normalizado,
--     columnas *_hash). La base nunca ve el teléfono o el correo en claro.
--   * Los eventos son de solo inserción: un trigger impide modificarlos o
--     borrarlos. El estado del trámite es una proyección de esos eventos.
--   * Ningún secreto vive aquí: códigos OTP y tokens se guardan como hash.
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS citext;

-- Actualiza actualizado_en en cada UPDATE.
CREATE OR REPLACE FUNCTION fn_tocar_actualizado() RETURNS trigger AS $$
BEGIN
  NEW.actualizado_en := now();
  RETURN NEW;
END $$ LANGUAGE plpgsql;

-- Impide modificar o borrar filas de tablas de solo inserción.
CREATE OR REPLACE FUNCTION fn_solo_insercion() RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'La tabla % es de solo inserción', TG_TABLE_NAME;
END $$ LANGUAGE plpgsql;

-- -----------------------------------------------------------------------------
-- 1. Organización, clínicas y personal
-- -----------------------------------------------------------------------------

CREATE TABLE organizaciones (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  nombre          text NOT NULL,
  slug            citext NOT NULL UNIQUE,
  zona_horaria    text NOT NULL DEFAULT 'America/Mexico_City',
  activa          boolean NOT NULL DEFAULT true,
  creado_en       timestamptz NOT NULL DEFAULT now(),
  actualizado_en  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE clinicas (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id uuid NOT NULL REFERENCES organizaciones(id),
  nombre          text NOT NULL,
  estado_mx       text,                   -- estado de la república (filtro del sitio)
  ciudad          text,
  direccion       text,
  latitud         numeric(9,6),
  longitud        numeric(9,6),
  telefono        text,                   -- teléfono público de la clínica
  activa          boolean NOT NULL DEFAULT true,
  creado_en       timestamptz NOT NULL DEFAULT now(),
  actualizado_en  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON clinicas (organizacion_id);

-- Personal: asesores (agentes humanos), recepción y administradores.
-- La autenticación del personal la hace un proveedor de identidad (OIDC/SSO);
-- aquí solo se guarda el sujeto externo, nunca contraseñas.
CREATE TABLE usuarios_internos (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id       uuid NOT NULL REFERENCES organizaciones(id),
  sujeto_externo        text NOT NULL,     -- "sub" del proveedor de identidad
  nombre                text NOT NULL,
  correo                citext NOT NULL,   -- correo de trabajo (Gmail / Workspace)
  telefono_e164         text,              -- para avisos por SMS
  rol                   text NOT NULL CHECK (rol IN ('asesor','supervisor','recepcion','admin')),
  clinica_id            uuid REFERENCES clinicas(id),  -- recepción de una clínica
  -- Disponibilidad para recibir escalamientos.
  disponibilidad        text NOT NULL DEFAULT 'desconectado'
                        CHECK (disponibilidad IN ('disponible','ocupado','ausente','desconectado')),
  max_casos_simultaneos smallint NOT NULL DEFAULT 3 CHECK (max_casos_simultaneos > 0),
  mfa_activo            boolean NOT NULL DEFAULT false,
  activo                boolean NOT NULL DEFAULT true,
  ultimo_acceso_en      timestamptz,
  creado_en             timestamptz NOT NULL DEFAULT now(),
  actualizado_en        timestamptz NOT NULL DEFAULT now(),
  UNIQUE (organizacion_id, sujeto_externo),
  UNIQUE (organizacion_id, correo)
);

-- -----------------------------------------------------------------------------
-- 2. Pacientes e identidad
-- -----------------------------------------------------------------------------

CREATE TABLE pacientes (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id        uuid NOT NULL REFERENCES organizaciones(id),
  -- Datos personales cifrados por la aplicación (AES-GCM con llave en KMS).
  nombre_cifrado         bytea,
  apellidos_cifrado      bytea,
  fecha_nacimiento_cifrada bytea,
  sexo                   text CHECK (sexo IN ('F','M','X')),
  -- CURP: el sitio la pide "si aplica". Se busca por identificadores_paciente
  -- (tipo 'curp'); aquí no se repite.
  -- Nivel de identidad más alto alcanzado (ver MODELO_DE_DATOS.md §2).
  nivel_identidad        text NOT NULL DEFAULT 'declarado'
                         CHECK (nivel_identidad IN ('declarado','verificado','verificado_fuerte')),
  estado                 text NOT NULL DEFAULT 'activo'
                         CHECK (estado IN ('provisional','activo','fusionado','baja')),
  -- Si este registro se fusionó con otro, apunta al que sobrevive.
  fusionado_en_id        uuid REFERENCES pacientes(id),
  canal_preferido        text CHECK (canal_preferido IN ('web','whatsapp','llamada','app','sms','email')),
  creado_en              timestamptz NOT NULL DEFAULT now(),
  actualizado_en         timestamptz NOT NULL DEFAULT now(),
  CHECK (estado <> 'fusionado' OR fusionado_en_id IS NOT NULL)
);
CREATE INDEX ON pacientes (organizacion_id);

-- Cada forma de reconocer al paciente en un canal: teléfono, correo, usuario
-- de la app, número de WhatsApp. Es la tabla que resuelve "¿quién es?".
CREATE TABLE identificadores_paciente (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  paciente_id      uuid NOT NULL REFERENCES pacientes(id),
  tipo             text NOT NULL CHECK (tipo IN ('telefono','correo','whatsapp','usuario_app','curp')),
  valor_hash       bytea NOT NULL,   -- HMAC-SHA256(valor normalizado), para buscar
  valor_cifrado    bytea NOT NULL,   -- valor real, cifrado
  valor_enmascarado text NOT NULL,   -- "+52 ••• ••• 1234", para mostrar
  verificado       boolean NOT NULL DEFAULT false,
  verificado_en    timestamptz,
  metodo_verificacion text CHECK (metodo_verificacion IN ('otp_sms','otp_whatsapp','otp_correo','whatsapp_entrante','caller_id','recepcion')),
  principal        boolean NOT NULL DEFAULT false,
  creado_en        timestamptz NOT NULL DEFAULT now(),
  actualizado_en   timestamptz NOT NULL DEFAULT now(),
  -- Un mismo teléfono verificado pertenece a un solo paciente por organización.
  UNIQUE (organizacion_id, tipo, valor_hash)
);
CREATE INDEX ON identificadores_paciente (paciente_id);

-- Sesión en un canal. Una sesión web puede empezar anónima (paciente_id nulo)
-- y quedar ligada al paciente cuando se verifica.
CREATE TABLE sesiones (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  paciente_id      uuid REFERENCES pacientes(id),
  canal            text NOT NULL CHECK (canal IN ('web','whatsapp','llamada','app','clinica')),
  nivel_identidad  text NOT NULL DEFAULT 'anonimo'
                   CHECK (nivel_identidad IN ('anonimo','declarado','verificado','verificado_fuerte')),
  token_hash       bytea UNIQUE,     -- hash del token de sesión, nunca el token
  ip_hash          bytea,            -- para detectar abuso sin guardar la IP
  agente_usuario   text,
  iniciada_en      timestamptz NOT NULL DEFAULT now(),
  ultima_actividad_en timestamptz NOT NULL DEFAULT now(),
  expira_en        timestamptz NOT NULL,
  cerrada_en       timestamptz
);
CREATE INDEX ON sesiones (paciente_id, ultima_actividad_en DESC);

-- Códigos OTP. Se guarda el hash del código, con límite de intentos y
-- caducidad corta. Ver MODELO_DE_DATOS.md §3.
CREATE TABLE verificaciones_otp (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  sesion_id        uuid REFERENCES sesiones(id),
  destino_hash     bytea NOT NULL,   -- HMAC del teléfono/correo al que se mandó
  medio            text NOT NULL CHECK (medio IN ('sms','whatsapp','correo')),
  proposito        text NOT NULL CHECK (proposito IN ('inicio_sesion','vincular_canal','confirmar_cambio')),
  codigo_hash      bytea NOT NULL,   -- HMAC(código + id); el código nunca se guarda
  intentos         smallint NOT NULL DEFAULT 0,
  max_intentos     smallint NOT NULL DEFAULT 5,
  creado_en        timestamptz NOT NULL DEFAULT now(),
  expira_en        timestamptz NOT NULL,
  consumido_en     timestamptz,
  bloqueado_en     timestamptz,
  CHECK (expira_en > creado_en),
  CHECK (intentos <= max_intentos)
);
-- Para limitar envíos por destino (p. ej. 3 cada 10 minutos).
CREATE INDEX ON verificaciones_otp (organizacion_id, destino_hash, creado_en DESC);

CREATE TABLE consentimientos (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  paciente_id      uuid NOT NULL REFERENCES pacientes(id),
  tipo             text NOT NULL CHECK (tipo IN ('aviso_privacidad','biometrico_facial','comunicaciones_whatsapp','comunicaciones_sms','comunicaciones_correo','grabacion_llamada')),
  version_texto    text NOT NULL,     -- versión exacta del texto aceptado
  otorgado         boolean NOT NULL,
  canal            text NOT NULL CHECK (canal IN ('web','whatsapp','llamada','app','clinica')),
  otorgado_en      timestamptz NOT NULL DEFAULT now(),
  revocado_en      timestamptz
);
CREATE INDEX ON consentimientos (paciente_id, tipo, otorgado_en DESC);

-- Referencia al rostro registrado en la API facial v2. Aquí NO se guarda el
-- vector ni la foto: solo dónde vive y bajo qué consentimiento.
CREATE TABLE rostros_registrados (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id    uuid NOT NULL REFERENCES organizaciones(id),
  paciente_id        uuid NOT NULL REFERENCES pacientes(id),
  consentimiento_id  uuid NOT NULL REFERENCES consentimientos(id),
  indice_v2          text NOT NULL DEFAULT 'pacientes',
  sujeto_id_v2       text NOT NULL,   -- = paciente_id
  vectores           smallint NOT NULL DEFAULT 0,
  registrado_en      timestamptz NOT NULL DEFAULT now(),
  borrado_en         timestamptz
);
CREATE UNIQUE INDEX ON rostros_registrados (paciente_id) WHERE borrado_en IS NULL;

-- -----------------------------------------------------------------------------
-- 3. Catálogo (estudios, precios, horarios)
-- -----------------------------------------------------------------------------

CREATE TABLE estudios (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  clave            text NOT NULL,
  nombre           text NOT NULL,
  categoria        text NOT NULL,     -- laboratorio, imagen, ...
  preparacion      text,              -- indicaciones para el paciente
  duracion_min     smallint NOT NULL DEFAULT 30,
  requiere_orden_medica boolean NOT NULL DEFAULT false,  -- resonancia, algunas tomografías, biopsias
  requiere_ayuno   boolean NOT NULL DEFAULT false,
  activo           boolean NOT NULL DEFAULT true,
  UNIQUE (organizacion_id, clave)
);

-- Paquetes (el WhatsApp de Salud Digna distingue "estudio individual" y "paquete").
CREATE TABLE paquetes (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  clave            text NOT NULL,
  nombre           text NOT NULL,
  activo           boolean NOT NULL DEFAULT true,
  UNIQUE (organizacion_id, clave)
);

CREATE TABLE paquete_estudios (
  paquete_id       uuid NOT NULL REFERENCES paquetes(id) ON DELETE CASCADE,
  estudio_id       uuid NOT NULL REFERENCES estudios(id),
  PRIMARY KEY (paquete_id, estudio_id)
);

CREATE TABLE precios_estudio (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  estudio_id       uuid NOT NULL REFERENCES estudios(id),
  clinica_id       uuid REFERENCES clinicas(id),   -- nulo = precio general
  precio           numeric(10,2) NOT NULL CHECK (precio >= 0),
  precio_en_linea  numeric(10,2) CHECK (precio_en_linea >= 0),  -- descuento por pagar en línea
  moneda           char(3) NOT NULL DEFAULT 'MXN',
  vigente_desde    date NOT NULL DEFAULT current_date,
  vigente_hasta    date
);
CREATE INDEX ON precios_estudio (estudio_id, clinica_id);

-- Espacios de agenda. "apartado" retiene el lugar mientras el paciente decide.
CREATE TABLE horarios (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  clinica_id       uuid NOT NULL REFERENCES clinicas(id),
  estudio_id       uuid NOT NULL REFERENCES estudios(id),
  inicia_en        timestamptz NOT NULL,
  termina_en       timestamptz NOT NULL,
  estado           text NOT NULL DEFAULT 'libre'
                   CHECK (estado IN ('libre','apartado','reservado','bloqueado')),
  apartado_hasta   timestamptz,
  version          integer NOT NULL DEFAULT 0,  -- concurrencia optimista
  CHECK (termina_en > inicia_en),
  CHECK (estado <> 'apartado' OR apartado_hasta IS NOT NULL)
);
CREATE INDEX ON horarios (clinica_id, estudio_id, inicia_en) WHERE estado = 'libre';

-- -----------------------------------------------------------------------------
-- 4. Trámite: el contexto y "en dónde se quedó"
-- -----------------------------------------------------------------------------

CREATE TABLE tramites (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id     uuid NOT NULL REFERENCES organizaciones(id),
  paciente_id         uuid REFERENCES pacientes(id),   -- nulo mientras es anónimo
  -- Quién agenda, si no es el propio paciente (una madre para su hijo).
  solicitante_paciente_id uuid REFERENCES pacientes(id),
  parentesco_solicitante text CHECK (parentesco_solicitante IN ('propio','hijo','padre_madre','pareja','otro')),
  paquete_id          uuid,                            -- si eligió un paquete
  sesion_origen_id    uuid REFERENCES sesiones(id),
  folio               text NOT NULL,                   -- legible: SD-2026-000123
  estado              text NOT NULL DEFAULT 'borrador' CHECK (estado IN (
                        'borrador','cotizado','clinica_elegida','horario_apartado',
                        'pendiente_confirmacion','confirmado','en_clinica','en_atencion',
                        'atendido','resultados_listos','cancelado','expirado','no_asistio')),
  estudio_id          uuid REFERENCES estudios(id),   -- estudio principal; todos en tramite_estudios
  clinica_id          uuid REFERENCES clinicas(id),
  horario_id          uuid REFERENCES horarios(id),
  precio_cotizado     numeric(10,2),
  metodo_pago         text CHECK (metodo_pago IN ('tarjeta_en_linea','oxxo_pay','coppel_pay','en_clinica')),
  estado_pago         text NOT NULL DEFAULT 'sin_pago' CHECK (estado_pago IN ('sin_pago','pendiente','pagado','reembolsado','fallido')),
  -- "En dónde se quedó": se actualizan con cada evento.
  paso_actual         text,           -- p. ej. 'confirmacion'
  siguiente_accion    text,           -- p. ej. 'confirmar_cita'
  canal_origen        text NOT NULL CHECK (canal_origen IN ('web','whatsapp','llamada','app','clinica','asesor')),
  canal_actual        text NOT NULL CHECK (canal_actual IN ('web','whatsapp','llamada','app','clinica','asesor')),
  canales_visitados   text[] NOT NULL DEFAULT '{}',
  -- Resumen corto y ANONIMIZADO para el asesor o el LLM.
  resumen_contexto    text,
  ultimo_evento_id    uuid,
  ultima_interaccion_en timestamptz NOT NULL DEFAULT now(),
  version             integer NOT NULL DEFAULT 0,      -- concurrencia optimista
  creado_en           timestamptz NOT NULL DEFAULT now(),
  actualizado_en      timestamptz NOT NULL DEFAULT now(),
  cerrado_en          timestamptz,
  UNIQUE (organizacion_id, folio)
);
CREATE INDEX ON tramites (paciente_id, ultima_interaccion_en DESC);
CREATE INDEX ON tramites (organizacion_id, estado);
ALTER TABLE tramites ADD FOREIGN KEY (paquete_id) REFERENCES paquetes(id);

-- Estudios del trámite (uno o varios, o los de un paquete).
CREATE TABLE tramite_estudios (
  tramite_id       uuid NOT NULL REFERENCES tramites(id) ON DELETE CASCADE,
  estudio_id       uuid NOT NULL REFERENCES estudios(id),
  precio           numeric(10,2),
  orden_medica_id  uuid,             -- documento subido, si el estudio la requiere
  PRIMARY KEY (tramite_id, estudio_id)
);

-- Documentos del paciente (orden médica). El archivo va en almacenamiento
-- privado y cifrado; aquí solo la referencia.
CREATE TABLE documentos (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  paciente_id      uuid NOT NULL REFERENCES pacientes(id),
  tramite_id       uuid REFERENCES tramites(id),
  tipo             text NOT NULL CHECK (tipo IN ('orden_medica','identificacion','comprobante_pago','otro')),
  ruta_almacen     text NOT NULL,
  sha256           bytea NOT NULL,
  tipo_mime        text NOT NULL,
  canal            text NOT NULL,
  subido_en        timestamptz NOT NULL DEFAULT now(),
  borrar_despues_de timestamptz
);

ALTER TABLE tramite_estudios ADD FOREIGN KEY (orden_medica_id) REFERENCES documentos(id);

-- Datos fiscales para factura (opcional).
CREATE TABLE datos_facturacion (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  paciente_id      uuid NOT NULL REFERENCES pacientes(id),
  rfc_cifrado      bytea NOT NULL,
  razon_social_cifrada bytea NOT NULL,
  regimen_fiscal   text,
  codigo_postal    text,
  uso_cfdi         text,
  correo_factura_cifrado bytea,
  creado_en        timestamptz NOT NULL DEFAULT now()
);

-- Lista de pasos del trámite y en qué canal se completó cada uno.
CREATE TABLE tramite_pasos (
  tramite_id       uuid NOT NULL REFERENCES tramites(id) ON DELETE CASCADE,
  paso             text NOT NULL CHECK (paso IN ('estudio','clinica','horario','datos_paciente','orden_medica','pago','preparacion_leida','confirmacion','checkin')),
  orden            smallint NOT NULL,
  completado       boolean NOT NULL DEFAULT false,
  canal            text CHECK (canal IN ('web','whatsapp','llamada','app','clinica','asesor')),
  completado_en    timestamptz,
  PRIMARY KEY (tramite_id, paso)
);

-- Dudas o datos faltantes que siguen abiertos. Lo primero que un canal ofrece
-- al paciente cuando vuelve.
CREATE TABLE pendientes (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  tramite_id       uuid NOT NULL REFERENCES tramites(id),
  tipo             text NOT NULL CHECK (tipo IN ('duda','dato_faltante','documento','pago','otro')),
  descripcion      text NOT NULL,     -- anonimizada
  canal_origen     text NOT NULL,
  abierto          boolean NOT NULL DEFAULT true,
  resuelto_por     text CHECK (resuelto_por IN ('paciente','bot','agente_voz','asesor','sistema')),
  creado_en        timestamptz NOT NULL DEFAULT now(),
  resuelto_en      timestamptz
);
CREATE INDEX ON pendientes (tramite_id) WHERE abierto;

CREATE TABLE citas (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  tramite_id       uuid NOT NULL REFERENCES tramites(id),
  paciente_id      uuid NOT NULL REFERENCES pacientes(id),
  clinica_id       uuid NOT NULL REFERENCES clinicas(id),
  horario_id       uuid NOT NULL REFERENCES horarios(id),
  estado           text NOT NULL DEFAULT 'confirmada'
                   CHECK (estado IN ('confirmada','reprogramada','cancelada','asistio','no_asistio')),
  qr_token_hash    bytea,            -- hash del token de check-in
  qr_expira_en     timestamptz,
  checkin_en       timestamptz,
  checkin_metodo   text CHECK (checkin_metodo IN ('qr','facial','manual')),
  -- Reagendar o cancelar pide folio + fecha de nacimiento + motivo.
  motivo_cambio    text CHECK (motivo_cambio IN ('no_puedo_asistir','cambio_de_clinica','cambio_de_estudio','precio','otro')),
  cancelada_en     timestamptz,
  confirmada_en    timestamptz NOT NULL DEFAULT now(),
  creado_en        timestamptz NOT NULL DEFAULT now(),
  actualizado_en   timestamptz NOT NULL DEFAULT now()
);
-- Un horario solo puede tener una cita vigente.
CREATE UNIQUE INDEX ON citas (horario_id) WHERE estado IN ('confirmada','reprogramada');

-- -----------------------------------------------------------------------------
-- 5. Conversaciones, mensajes y llamadas
-- -----------------------------------------------------------------------------

CREATE TABLE conversaciones (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id    uuid NOT NULL REFERENCES organizaciones(id),
  paciente_id        uuid REFERENCES pacientes(id),
  tramite_id         uuid REFERENCES tramites(id),
  sesion_id          uuid REFERENCES sesiones(id),
  canal              text NOT NULL CHECK (canal IN ('web','whatsapp','app')),
  -- Quién contesta ahora: el bot o un asesor humano (escalamiento).
  atendida_por       text NOT NULL DEFAULT 'bot' CHECK (atendida_por IN ('bot','asesor')),
  asesor_id          uuid REFERENCES usuarios_internos(id),
  estado             text NOT NULL DEFAULT 'abierta' CHECK (estado IN ('abierta','en_espera_asesor','con_asesor','cerrada')),
  id_externo         text,           -- id del hilo en WhatsApp, etc.
  abierta_en         timestamptz NOT NULL DEFAULT now(),
  ultimo_mensaje_en  timestamptz NOT NULL DEFAULT now(),
  cerrada_en         timestamptz,
  CHECK (atendida_por <> 'asesor' OR asesor_id IS NOT NULL)
);
CREATE INDEX ON conversaciones (paciente_id, ultimo_mensaje_en DESC);

-- El texto de un mensaje puede traer datos de salud: va cifrado y con fecha
-- de borrado (retención). Los eventos solo guardan el id del mensaje.
CREATE TABLE mensajes (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id    uuid NOT NULL REFERENCES organizaciones(id),
  conversacion_id    uuid NOT NULL REFERENCES conversaciones(id),
  direccion          text NOT NULL CHECK (direccion IN ('entrante','saliente')),
  autor_tipo         text NOT NULL CHECK (autor_tipo IN ('paciente','bot','asesor','sistema')),
  autor_id           uuid REFERENCES usuarios_internos(id),   -- si fue un asesor
  texto_cifrado      bytea,
  tipo_contenido     text NOT NULL DEFAULT 'texto' CHECK (tipo_contenido IN ('texto','imagen','documento','audio','plantilla','interactivo')),
  intencion          text,           -- clasificada por NLP
  confianza_intencion numeric(4,3),
  id_externo         text,           -- wamid de WhatsApp, etc.
  estado_entrega     text CHECK (estado_entrega IN ('enviado','entregado','leido','fallido')),
  creado_en          timestamptz NOT NULL DEFAULT now(),
  borrar_despues_de  timestamptz,
  UNIQUE (organizacion_id, id_externo)
);
CREATE INDEX ON mensajes (conversacion_id, creado_en);

CREATE TABLE llamadas (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id    uuid NOT NULL REFERENCES organizaciones(id),
  paciente_id        uuid REFERENCES pacientes(id),
  tramite_id         uuid REFERENCES tramites(id),
  proveedor          text NOT NULL DEFAULT 'retell',
  id_llamada_externo text NOT NULL,  -- call_id de Retell
  numero_hash        bytea NOT NULL, -- HMAC del número que llamó
  direccion          text NOT NULL DEFAULT 'entrante' CHECK (direccion IN ('entrante','saliente')),
  iniciada_en        timestamptz NOT NULL,
  terminada_en       timestamptz,
  duracion_s         integer,
  razon_fin          text,
  resumen            text,           -- anonimizado
  sentimiento        text CHECK (sentimiento IN ('positivo','neutro','negativo')),
  grabacion_permitida boolean NOT NULL DEFAULT false,
  UNIQUE (proveedor, id_llamada_externo)
);
CREATE INDEX ON llamadas (paciente_id, iniciada_en DESC);

-- -----------------------------------------------------------------------------
-- 6. Escalamiento a un agente humano
-- -----------------------------------------------------------------------------

-- Dos modalidades:
--   * en_vivo: web, WhatsApp o app. Un asesor toma la conversación.
--   * devolucion_llamada: la llamada con Retell NO se transfiere. El agente de
--     voz avisa que alguien se comunicará al mismo número y se crea esta
--     solicitud para que un asesor llame o escriba después.
CREATE TABLE escalamientos (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id       uuid NOT NULL REFERENCES organizaciones(id),
  paciente_id           uuid REFERENCES pacientes(id),
  tramite_id            uuid REFERENCES tramites(id),
  modalidad             text NOT NULL CHECK (modalidad IN ('en_vivo','devolucion_llamada')),
  canal_origen          text NOT NULL CHECK (canal_origen IN ('web','whatsapp','app','llamada')),
  conversacion_id       uuid REFERENCES conversaciones(id),
  llamada_id            uuid REFERENCES llamadas(id),
  motivo                text NOT NULL CHECK (motivo IN ('pidio_humano','duda_medica','queja','pago','bot_no_entendio','urgencia','otro')),
  detalle               text,              -- anonimizado
  prioridad             text NOT NULL DEFAULT 'normal' CHECK (prioridad IN ('baja','normal','alta','urgente')),
  estado                text NOT NULL DEFAULT 'abierto' CHECK (estado IN (
                          'abierto','notificado','asignado','en_atencion',
                          'contacto_fallido','resuelto','cancelado','vencido')),
  -- Para devolucion_llamada: a dónde contactar. Por defecto el mismo número.
  contacto_hash         bytea,
  contacto_cifrado      bytea,
  contactar_por         text CHECK (contactar_por IN ('llamada','whatsapp','sms')),
  ventana_preferida     tstzrange,         -- "por la tarde", si lo dijo
  asignado_a            uuid REFERENCES usuarios_internos(id),
  asignado_en           timestamptz,
  primer_respuesta_en   timestamptz,
  resuelto_en           timestamptz,
  resolucion            text,
  intentos_contacto     smallint NOT NULL DEFAULT 0,
  sla_respuesta_vence_en timestamptz NOT NULL,   -- p. ej. 5 min en vivo, 2 h devolución
  creado_por            text NOT NULL CHECK (creado_por IN ('bot','agente_voz','paciente','asesor','sistema')),
  creado_en             timestamptz NOT NULL DEFAULT now(),
  actualizado_en        timestamptz NOT NULL DEFAULT now(),
  CHECK (modalidad <> 'en_vivo' OR conversacion_id IS NOT NULL),
  CHECK (modalidad <> 'devolucion_llamada' OR contacto_hash IS NOT NULL),
  CHECK (estado NOT IN ('asignado','en_atencion','resuelto') OR asignado_a IS NOT NULL)
);
CREATE INDEX ON escalamientos (organizacion_id, estado, prioridad, creado_en)
  WHERE estado IN ('abierto','notificado','asignado','en_atencion','contacto_fallido');
CREATE INDEX ON escalamientos (asignado_a) WHERE estado IN ('asignado','en_atencion');

-- Historial de cada escalamiento (quién lo tomó, intentos de contacto, notas).
CREATE TABLE escalamiento_movimientos (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  escalamiento_id  uuid NOT NULL REFERENCES escalamientos(id),
  tipo             text NOT NULL CHECK (tipo IN ('creado','notificado','asignado','reasignado','tomado','intento_contacto','nota','resuelto','cancelado','vencido')),
  usuario_id       uuid REFERENCES usuarios_internos(id),
  detalle          text,
  creado_en        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON escalamiento_movimientos (escalamiento_id, creado_en);

-- -----------------------------------------------------------------------------
-- 7. Notificaciones (SMS y correo/Gmail) a asesores y pacientes
-- -----------------------------------------------------------------------------

-- Qué avisos quiere cada asesor y por qué medio.
CREATE TABLE preferencias_notificacion (
  usuario_id       uuid NOT NULL REFERENCES usuarios_internos(id),
  evento           text NOT NULL CHECK (evento IN ('escalamiento_nuevo','escalamiento_asignado','escalamiento_por_vencer','devolucion_pendiente','resumen_diario')),
  medio            text NOT NULL CHECK (medio IN ('sms','correo','tablero')),
  activo           boolean NOT NULL DEFAULT true,
  solo_prioridad_minima text NOT NULL DEFAULT 'baja' CHECK (solo_prioridad_minima IN ('baja','normal','alta','urgente')),
  PRIMARY KEY (usuario_id, evento, medio)
);

-- Plantillas de los mensajes (sin datos del paciente; se rellenan al enviar).
CREATE TABLE plantillas_notificacion (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  clave            text NOT NULL,      -- 'escalamiento_nuevo_sms'
  medio            text NOT NULL CHECK (medio IN ('sms','correo','whatsapp')),
  asunto           text,               -- solo correo
  cuerpo           text NOT NULL,      -- con variables {{folio}}, {{enlace}}
  version          integer NOT NULL DEFAULT 1,
  activa           boolean NOT NULL DEFAULT true,
  UNIQUE (organizacion_id, clave, version)
);

-- Cola de salida. Un trabajador toma las 'pendiente', las manda por el
-- proveedor (Gmail API / SMTP, proveedor de SMS) y guarda el resultado.
CREATE TABLE notificaciones (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id     uuid NOT NULL REFERENCES organizaciones(id),
  destinatario_tipo   text NOT NULL CHECK (destinatario_tipo IN ('usuario_interno','paciente')),
  usuario_id          uuid REFERENCES usuarios_internos(id),
  paciente_id         uuid REFERENCES pacientes(id),
  medio               text NOT NULL CHECK (medio IN ('sms','correo','whatsapp')),
  proveedor           text NOT NULL CHECK (proveedor IN ('gmail','smtp','twilio','whatsapp_cloud','simulado')),
  destino_cifrado     bytea NOT NULL,  -- número o correo, cifrado
  destino_enmascarado text NOT NULL,
  plantilla_id        uuid REFERENCES plantillas_notificacion(id),
  variables           jsonb NOT NULL DEFAULT '{}',  -- sin datos de salud
  motivo              text NOT NULL,   -- 'escalamiento_nuevo', 'recordatorio_cita', ...
  escalamiento_id     uuid REFERENCES escalamientos(id),
  tramite_id          uuid REFERENCES tramites(id),
  estado              text NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente','enviando','enviada','entregada','fallida','cancelada')),
  intentos            smallint NOT NULL DEFAULT 0,
  max_intentos        smallint NOT NULL DEFAULT 3,
  programada_para     timestamptz NOT NULL DEFAULT now(),
  id_externo          text,            -- id del proveedor (message id)
  ultimo_error        text,
  clave_idempotencia  text NOT NULL,
  creado_en           timestamptz NOT NULL DEFAULT now(),
  enviada_en          timestamptz,
  UNIQUE (organizacion_id, clave_idempotencia),
  CHECK ((destinatario_tipo = 'usuario_interno') = (usuario_id IS NOT NULL)),
  CHECK ((destinatario_tipo = 'paciente') = (paciente_id IS NOT NULL))
);
CREATE INDEX ON notificaciones (estado, programada_para) WHERE estado IN ('pendiente','fallida');

-- -----------------------------------------------------------------------------
-- 8. Eventos (línea de tiempo unificada), idempotencia y auditoría
-- -----------------------------------------------------------------------------

CREATE TABLE eventos (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organizacion_id    uuid NOT NULL REFERENCES organizaciones(id),
  tipo               text NOT NULL,     -- catálogo en FLUJO_Y_ENDPOINTS.md §4
  version_esquema    smallint NOT NULL DEFAULT 1,
  ocurrio_en         timestamptz NOT NULL,
  registrado_en      timestamptz NOT NULL DEFAULT now(),
  canal              text NOT NULL CHECK (canal IN ('web','whatsapp','llamada','app','clinica','asesor','sistema')),
  actor_tipo         text NOT NULL CHECK (actor_tipo IN ('paciente','asesor','agente_voz','bot','recepcion','sistema')),
  actor_id           text,
  paciente_id        uuid REFERENCES pacientes(id),
  tramite_id         uuid REFERENCES tramites(id),
  sesion_id          uuid REFERENCES sesiones(id),
  correlacion_id     text,              -- call_id, id de conversación, etc.
  clave_idempotencia text,
  datos              jsonb NOT NULL DEFAULT '{}',   -- solo ids y valores de catálogo
  UNIQUE (organizacion_id, clave_idempotencia)
);
CREATE INDEX ON eventos (paciente_id, ocurrio_en DESC);
CREATE INDEX ON eventos (tramite_id, ocurrio_en);
CREATE INDEX ON eventos (organizacion_id, tipo, ocurrio_en DESC);
CREATE TRIGGER eventos_solo_insercion BEFORE UPDATE OR DELETE ON eventos
  FOR EACH ROW EXECUTE FUNCTION fn_solo_insercion();

-- Webhooks ya procesados (WhatsApp y Retell reintentan).
CREATE TABLE webhooks_recibidos (
  proveedor        text NOT NULL,
  id_externo       text NOT NULL,
  recibido_en      timestamptz NOT NULL DEFAULT now(),
  procesado_en     timestamptz,
  resultado        text,
  PRIMARY KEY (proveedor, id_externo)
);

-- Quién vio o cambió datos de qué paciente. Incluye LECTURAS.
CREATE TABLE auditoria_accesos (
  id               bigserial PRIMARY KEY,
  organizacion_id  uuid NOT NULL REFERENCES organizaciones(id),
  actor_tipo       text NOT NULL CHECK (actor_tipo IN ('usuario_interno','paciente','servicio')),
  actor_id         text NOT NULL,
  accion           text NOT NULL CHECK (accion IN ('leer','crear','modificar','borrar','exportar','descifrar')),
  recurso          text NOT NULL,       -- 'paciente', 'mensaje', ...
  recurso_id       text NOT NULL,
  paciente_id      uuid,
  motivo           text,                -- p. ej. 'atencion_escalamiento'
  ip_hash          bytea,
  ocurrio_en       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON auditoria_accesos (paciente_id, ocurrio_en DESC);
CREATE INDEX ON auditoria_accesos (organizacion_id, actor_id, ocurrio_en DESC);
CREATE TRIGGER auditoria_solo_insercion BEFORE UPDATE OR DELETE ON auditoria_accesos
  FOR EACH ROW EXECUTE FUNCTION fn_solo_insercion();

-- -----------------------------------------------------------------------------
-- 9. Triggers de actualizado_en
-- -----------------------------------------------------------------------------

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['organizaciones','clinicas','usuarios_internos','pacientes',
                           'identificadores_paciente','tramites','citas','escalamientos']
  LOOP
    EXECUTE format('CREATE TRIGGER %I_actualizado BEFORE UPDATE ON %I
                    FOR EACH ROW EXECUTE FUNCTION fn_tocar_actualizado()', t, t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 10. Row Level Security por organización
--
-- La aplicación abre cada transacción con:
--   SET LOCAL app.organizacion_id = '<uuid>';
-- y se conecta con un rol sin BYPASSRLS. Una consulta sin esa variable no ve
-- nada.
-- -----------------------------------------------------------------------------

DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['clinicas','usuarios_internos','pacientes','identificadores_paciente',
                           'sesiones','verificaciones_otp','consentimientos','rostros_registrados',
                           'estudios','paquetes','precios_estudio','horarios','tramites','documentos','datos_facturacion','pendientes','citas',
                           'conversaciones','mensajes','llamadas','escalamientos',
                           'plantillas_notificacion','notificaciones','eventos','auditoria_accesos']
  LOOP
    EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
    EXECUTE format($p$CREATE POLICY por_organizacion ON %I
                     USING (organizacion_id = nullif(current_setting('app.organizacion_id', true), '')::uuid)
                     WITH CHECK (organizacion_id = nullif(current_setting('app.organizacion_id', true), '')::uuid)$p$, t);
  END LOOP;
END $$;

-- -----------------------------------------------------------------------------
-- 11. Vista: contexto del paciente para un canal o un asesor
--     (lo que devuelve GET /pacientes/{id}/contexto)
-- -----------------------------------------------------------------------------

CREATE VIEW v_contexto_tramite WITH (security_invoker = true) AS
SELECT
  t.organizacion_id,
  t.paciente_id,
  t.id                  AS tramite_id,
  t.folio,
  t.estado,
  t.paso_actual,
  t.siguiente_accion,
  t.canal_actual,
  t.canales_visitados,
  t.resumen_contexto,
  t.ultima_interaccion_en,
  e.nombre              AS estudio,
  c.nombre              AS clinica,
  h.inicia_en           AS horario,
  (SELECT count(*) FROM pendientes p WHERE p.tramite_id = t.id AND p.abierto) AS pendientes_abiertos,
  (SELECT count(*) FROM escalamientos s WHERE s.tramite_id = t.id
     AND s.estado IN ('abierto','notificado','asignado','en_atencion','contacto_fallido')) AS escalamientos_abiertos,
  t.version
FROM tramites t
LEFT JOIN estudios e ON e.id = t.estudio_id
LEFT JOIN clinicas c ON c.id = t.clinica_id
LEFT JOIN horarios h ON h.id = t.horario_id
WHERE t.estado NOT IN ('resultados_listos','cancelado');
